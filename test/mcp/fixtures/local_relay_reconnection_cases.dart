import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/external/windows_local_relay.dart';
import 'package:shiroha_quiz/mcp/vnext_local_relay_port.dart';

final class _Connection implements LocalRelayConnection {
  @override
  bool isCurrent = false;
  final sent = <Map<String, Object?>>[];
  int closes = 0;
  Future<Map<String, Object?>> Function()? onReceive;
  Future<void> Function()? onClose;
  @override
  Future<void> accept() async => isCurrent = true;
  @override
  Future<void> send(Map<String, Object?> value, Duration deadline) async {
    if (!isCurrent) throw const LocalRelayException();
    sent.add(value);
  }

  @override
  Future<Map<String, Object?>> receive(Duration deadline) async =>
      onReceive == null
          ? {
              'version': 1,
              'id': sent.last['id'],
              'result': {
                'profileVersion': 2,
                'data': {'observed': true},
                'error': null
              }
            }
          : await onReceive!();
  @override
  Future<void> close() async {
    closes++;
    isCurrent = false;
    await onClose?.call();
  }
}

Future<Map<String, Object?>> _call(VnextLocalRelayPort port,
        {String tool = 'open_generation_context',
        Map<String, dynamic> arguments = const {},
        Stream<void> cancelled = const Stream.empty()}) =>
    port.call(tool, arguments, cancelled: cancelled, available: () => true);

void localRelayReconnectionCases() {
  test('relay unknown acquisition never permits another connection', () async {
    var attempts = 0;
    final port = VnextLocalRelayPort(connect: () {
      attempts++;
      throw const LocalRelayException(unsettled: true);
    });
    expect((await _call(port))['error'], 'unavailable');
    expect((await _call(port))['error'], 'unavailable');
    expect(attempts, 1);
    await expectLater(port.close(), throwsA(isA<LocalRelayException>()));
  });
  test(
      'relay discovers without connecting and later call recovers from absent App',
      () async {
    var attempts = 0;
    final connection = _Connection();
    final port = VnextLocalRelayPort(connect: () {
      if (++attempts == 1) throw const LocalRelayException();
      return connection;
    });
    expect(attempts, 0);
    expect((await _call(port))['error'], 'unavailable');
    expect(attempts, 1);
    expect((await _call(port))['error'], isNull);
    expect(attempts, 2);
    expect(connection.sent, hasLength(1));
    await port.close();
  });

  test('relay keeps pending cleanup exclusive before another independent call',
      () async {
    final gate = Completer<void>();
    final entered = Completer<void>();
    final first = _Connection()
      ..onReceive = () async {
        throw const LocalRelayException();
      }
      ..onClose = () {
        entered.complete();
        return gate.future;
      };
    final second = _Connection();
    var opened = 0;
    final port =
        VnextLocalRelayPort(connect: () => ++opened == 1 ? first : second);
    final failed = _call(port);
    await entered.future;
    expect((await _call(port))['error'], 'busy');
    expect(opened, 1);
    gate.complete();
    expect((await failed)['error'], 'unavailable');
    expect((await _call(port))['error'], isNull);
    expect(opened, 2);
    expect(first.closes, 1);
    await port.close();
  });

  test(
      'relay failed close stays terminal and cannot be replaced or hidden at exit',
      () async {
    final connection = _Connection()
      ..onReceive = () async {
        throw const LocalRelayException();
      }
      ..onClose = () async {
        throw const LocalRelayException(unsettled: true);
      };
    var opened = 0;
    final port = VnextLocalRelayPort(connect: () {
      opened++;
      return connection;
    });
    expect((await _call(port))['error'], 'unavailable');
    expect((await _call(port))['error'], 'unavailable');
    expect(opened, 1);
    await expectLater(port.close(), throwsA(isA<LocalRelayException>()));
    await expectLater(port.close(), throwsA(isA<LocalRelayException>()));
    expect(connection.closes, 1);
  });

  test(
      'relay lost STAGE response is unknown and only original-key READ reconnects',
      () async {
    final first = _Connection()
      ..onReceive = () async => throw const LocalRelayException();
    final second = _Connection();
    var opened = 0;
    final port =
        VnextLocalRelayPort(connect: () => ++opened == 1 ? first : second);
    const key = 'original-submission-key';
    expect(
        (await _call(port, tool: 'propose_generated_questions', arguments: {
          'submission': {'submissionKey': key}
        }))['error'],
        'outcome_unknown');
    expect(opened, 1);
    expect(first.sent, hasLength(1));
    expect(
        (await _call(port,
            tool: 'get_question_proposal',
            arguments: {'submissionKey': key}))['error'],
        isNull);
    expect(second.sent.single['tool'], 'get_question_proposal');
    expect(second.sent.single['arguments'], {'submissionKey': key});
    expect(first.sent, hasLength(1));
    await port.close();
  });

  test('relay idle peer loss joins original close before opening a new peer',
      () async {
    final first = _Connection(), second = _Connection();
    var opened = 0;
    final port =
        VnextLocalRelayPort(connect: () => ++opened == 1 ? first : second);
    await _call(port);
    await _call(port);
    expect(first.sent.map((request) => request['id']), [1, 2]);
    first.isCurrent = false;
    expect((await _call(port))['error'], isNull);
    expect(first.closes, 1);
    expect(first.sent, hasLength(2));
    expect(second.sent, hasLength(1));
    expect(second.sent.single['id'], 1);
    await port.close();
    expect((await _call(port))['error'], 'unavailable');
    expect(opened, 2);
  });

  test(
      'relay observed cancellation suppresses a late result without stopping server',
      () async {
    final response = Completer<Map<String, Object?>>();
    final entered = Completer<void>();
    final cancel = StreamController<void>();
    final first = _Connection()
      ..onReceive = () {
        entered.complete();
        return response.future;
      }
      ..onClose = () async {
        response.completeError(const LocalRelayException());
      };
    final second = _Connection();
    var opened = 0;
    final port =
        VnextLocalRelayPort(connect: () => ++opened == 1 ? first : second);
    final work = _call(port, cancelled: cancel.stream);
    await entered.future;
    cancel.add(null);
    expect((await work)['error'], 'unavailable');
    expect(first.closes, 1);
    expect((await _call(port))['error'], isNull);
    await cancel.close();
    await port.close();
  });
}
