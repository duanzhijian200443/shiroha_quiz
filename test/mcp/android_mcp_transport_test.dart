import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/mcp/android_mcp_transport.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_server.dart';

final class _App implements VnextMcpPort {
  int calls = 0, closes = 0;
  final entered = Completer<void>(), release = Completer<void>();
  bool cancelled = false;
  @override
  Future<Map<String, Object?>> call(String tool, Map<String, dynamic> arguments,
      {required Stream<void> cancelled,
      required bool Function() available}) async {
    calls++;
    entered.complete();
    final sub = cancelled.listen((_) => this.cancelled = true);
    await release.future;
    await sub.cancel();
    return available()
        ? {'profileVersion': 2, 'data': {}, 'error': null}
        : vnextFailure('unavailable');
  }

  @override
  Future<void> close() async {
    closes++;
  }
}

void main() {
  test(
      'seven schemas stay unchanged while Android STAGE/file routes never enter App',
      () async {
    final app = _App();
    final port = AndroidReadOnlyPort(app, () => true);
    expect(VnextMcpServer.inputSchemas.length, 7);
    for (final tool in [
      'propose_generated_questions',
      'get_question_proposal',
      'retrieve_file_content',
      'get_file_passage'
    ]) {
      expect(
          (await port.call(tool, {},
              cancelled: const Stream.empty(), available: () => true))['error'],
          'unavailable');
    }
    expect(app.calls, 0);
    await port.close();
  });
  test(
      'single call slot; connection close cancels and joins without closing App host',
      () async {
    final app = _App();
    final port = AndroidReadOnlyPort(app, () => true);
    final call = port.call('search_questions', {},
        cancelled: const Stream.empty(), available: () => true);
    await app.entered.future;
    expect(
        (await port.call('get_question_detail', {},
            cancelled: const Stream.empty(), available: () => true))['error'],
        'resourceLimit');
    var settled = false;
    final closing = port.close().then((_) => settled = true);
    await Future<void>.delayed(Duration.zero);
    expect(app.cancelled, isTrue);
    expect(settled, isFalse);
    expect(app.closes, 0);
    app.release.complete();
    expect((await call)['error'], 'unavailable');
    await closing;
    expect(settled, isTrue);
    expect(app.closes, 0);
  });
}
