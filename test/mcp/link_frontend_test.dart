import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:shiroha_quiz/data/external/windows_local_relay.dart';
import 'package:shiroha_quiz/mcp/link_frontend.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_server.dart';
import 'package:shiroha_quiz/data/external/link/link_call_diagnostics.dart';
import 'package:shiroha_quiz/data/external/link/link_call_capture.dart';

/// Synthetic IPC only. MCP negotiation, validation and output use the real SDK.
final class Channel implements LocalRelayConnection {
  final messages = <Map<String, Object?>>[];
  final attachEntered = Completer<void>();
  final callEntered = Completer<void>();
  final attachGate = Completer<void>();
  final resultGate = Completer<void>();
  bool holdAttach = false, busy = false, closed = false;
  int receives = 0;
  int? failReceive;
  bool failSend = false;
  Object failure = const LocalRelayException();
  Map<String, Object?>? resultOverride;
  final resultFrameOverrides = <String, Object?>{};
  @override
  bool get isCurrent => !closed;
  @override
  Future<void> accept() async {
    if (busy) throw const LocalRelayException(busy: true);
  }

  @override
  Future<void> send(Map<String, Object?> message, Duration deadline) async {
    if (failSend && message['kind'] == 'call') throw failure;
    messages.add(message);
    if (message['kind'] == 'call' && !callEntered.isCompleted) {
      callEntered.complete();
    }
  }

  @override
  Future<Map<String, Object?>> receive(Duration deadline) async {
    if (failReceive == receives + 1) throw failure;
    final envelope = <String, Object?>{
      'version': 1,
      'runId': 'test-run',
      'connectionId': 'test-connection'
    };
    switch (++receives) {
      case 1:
        return {
          ...envelope,
          'kind': 'hello',
          'capabilitySet': 'shiroha.profile3.base11'
        };
      case 2:
        attachEntered.complete();
        if (holdAttach) await attachGate.future;
        return {...envelope, 'kind': 'attached', 'leaseId': 'test-lease'};
      default:
        await resultGate.future;
        if (closed) throw const LocalRelayException();
        return {
          ...envelope,
          'kind': 'result',
          'id': messages.lastWhere((m) => m['kind'] == 'call')['id'],
          'result':
              resultOverride ?? vnextFailure('unavailable', profileVersion: 3),
          ...resultFrameOverrides,
        };
    }
  }

  @override
  Future<void> close() async {
    closed = true;
    if (!attachGate.isCompleted) attachGate.complete();
    if (!resultGate.isCompleted) resultGate.complete();
  }
}

final class ObservedOutput extends IOStreamTransport {
  ObservedOutput({required super.stream, required super.sink});
  Completer<void>? outputGate;
  final writing = Completer<void>();
  @override
  Future<void> send(JsonRpcMessage message, {int? relatedRequestId}) async {
    if (outputGate != null && message is JsonRpcResponse) {
      if (!writing.isCompleted) writing.complete();
      await outputGate!.future;
    }
    await super.send(message, relatedRequestId: relatedRequestId);
  }
}

final class EofChannel extends Channel {
  final closeEntered = Completer<void>(), closeGate = Completer<void>();
  final delivered = Completer<void>();
  final deliveries = <int, Completer<void>>{};
  int closes = 0;
  bool failClose = false;
  @override
  Future<void> send(Map<String, Object?> message, Duration deadline) async {
    await super.send(message, deadline);
    if (message['kind'] == 'delivered') {
      if (!delivered.isCompleted) delivered.complete();
      deliveries
          .putIfAbsent(message['id'] as int, Completer<void>.new)
          .complete();
    }
  }

  @override
  Future<void> close() async {
    closes++;
    if (!closeEntered.isCompleted) closeEntered.complete();
    await closeGate.future;
    if (failClose) throw StateError('synthetic original close failure');
    await super.close();
  }
}

final class ControlledCaptureFile implements RandomAccessFile {
  ControlledCaptureFile(this.inner,
      {this.failCallWrite = false,
      this.holdFlush = false,
      this.failFooterFlush = false,
      this.failClose = false});
  final RandomAccessFile inner;
  final bool failCallWrite, holdFlush;
  final bool failFooterFlush, failClose;
  final callObserved = Completer<void>(), flushEntered = Completer<void>();
  final callRecords = List.generate(5, (_) => Completer<void>());
  final flushGate = Completer<void>(), flushCompleted = Completer<void>();
  bool _callSeen = false;
  bool _footerSeen = false;
  @override
  Future<RandomAccessFile> writeFrom(List<int> buffer,
      [int start = 0, int? end]) async {
    final row = jsonDecode(utf8.decode(buffer.sublist(start, end))) as Map;
    if (row['e'] == 'capture-finished') _footerSeen = true;
    if (row['e'] == 'call') {
      _callSeen = true;
      if (!callObserved.isCompleted) callObserved.complete();
      final ordinal = row['n'] as int;
      if (ordinal <= 5) callRecords[ordinal - 1].complete();
      if (failCallWrite) throw StateError('SENTINEL_WRITE_ERROR');
    }
    await inner.writeFrom(buffer, start, end);
    return this;
  }

  @override
  Future<RandomAccessFile> flush() async {
    if (_callSeen && holdFlush) {
      if (!flushEntered.isCompleted) flushEntered.complete();
      await flushGate.future;
    }
    await inner.flush();
    if (_footerSeen && failFooterFlush) {
      throw StateError('SENTINEL_FOOTER_FLUSH');
    }
    if (_callSeen && !flushCompleted.isCompleted) flushCompleted.complete();
    return this;
  }

  @override
  Future<void> close() async {
    await inner.close();
    if (failClose) throw StateError('SENTINEL_CAPTURE_CLOSE');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final mode in [
    'normal',
    'write-fails',
    'flush-held',
    'footer-flush-fails',
    'capture-close-fails',
    'sixth-call',
    'lifecycle-observer-fails'
  ]) {
    for (final failedClose in [false, true]) {
      test(
          'v2 automatic attached EOF retains original close under $mode failure=$failedClose',
          () async {
        final directory =
            await Directory.systemTemp.createTemp('link-closure-capture-');
        late ControlledCaptureFile captureFile;
        final capture = LinkCallCapture(
            LinkCaptureConfig(
                '12345678-1234-1234-1234-123456789abc', directory.path,
                formatVersion: 2),
            frontend: true,
            processStarted: () => '123456789',
            openFile: (file) async => captureFile = ControlledCaptureFile(
                await file.open(mode: FileMode.writeOnlyAppend),
                failCallWrite: mode == 'write-fails',
                holdFlush: mode == 'flush-held',
                failFooterFlush: mode == 'footer-flush-fails',
                failClose: mode == 'capture-close-fails'));
        await capture.start();
        final channel = EofChannel()..failClose = failedClose;
        channel.resultOverride = {
          'profileVersion': 3,
          'data': <String, dynamic>{},
          'error': null,
          'source': {'kind': 'android', 'deviceRef': 'synthetic'}
        };
        channel.resultGate.complete();
        final port = LinkFrontendPort(
            openChannel: () => channel,
            diagnostics: LinkFrontendDiagnostics(capture.diagnostics,
                lifecycleObserver: (checkpoint, outcome) {
              if (mode == 'lifecycle-observer-fails') {
                throw StateError('SENTINEL_OBSERVER');
              }
              capture.lifecycle(checkpoint, outcome);
            }));
        final toServer = StreamController<List<int>>(),
            toClient = StreamController<List<int>>();
        final server = VnextMcpServer(port, profileVersion: 3);
        final client = McpClient(
            const Implementation(name: 'closure-capture', version: '1'));
        final originalJoined = Completer<void>();
        var originalClosed = false, complete = false, capturePassed = false;
        final serving = () async {
          try {
            await server.serveTransport(LinkFrontendTransport(
                IOStreamTransport(stream: toServer.stream, sink: toClient.sink),
                port));
            originalClosed = true;
          } finally {
            originalJoined.complete();
            capturePassed =
                await capture.finish(originalClosed: originalClosed);
            complete = true;
          }
        }()
            .then<Object?>((_) => null, onError: (Object error) => error);
        try {
          await client.connect(
              IOStreamTransport(stream: toClient.stream, sink: toServer.sink));
          for (var i = 0; i < (mode == 'sixth-call' ? 6 : 1); i++) {
            final response = await client.callTool(
                const CallToolRequest(name: 'open_context', arguments: {}));
            expect(response.isError, isNot(isTrue));
            if (mode == 'sixth-call') {
              if (i < 5) {
                await captureFile.callRecords[i].future;
              } else {
                await channel.deliveries
                    .putIfAbsent(i + 1, Completer<void>.new)
                    .future;
              }
            }
          }
          await captureFile.callObserved.future
              .timeout(const Duration(seconds: 2));
          if (mode == 'flush-held') await captureFile.flushEntered.future;
          final eof = toServer.close();
          await channel.closeEntered.future.timeout(const Duration(seconds: 2));
          final close = port.close();
          expect(identical(close, port.close()), isTrue);
          final observedClose = close.then<Object?>((_) => null,
              onError: (Object error) => error);
          expect(complete, isFalse);
          channel.closeGate.complete();
          await originalJoined.future.timeout(const Duration(seconds: 2));
          expect(await observedClose, failedClose ? isStateError : isNull);
          expect(channel.closes, 1);
          if (mode == 'flush-held') {
            // Original close is done while diagnostic flush remains blocked.
            expect(complete, isFalse);
            captureFile.flushGate.complete();
          }
          expect(await serving.timeout(const Duration(seconds: 2)),
              failedClose ? isStateError : isNull);
          await eof;
          expect(capturePassed,
              !failedClose && (mode == 'normal' || mode == 'flush-held'));
          expect(
              capture.exitCodeAfterFinish(failedClose ? 78 : 0,
                  complete: capturePassed),
              failedClose
                  ? 78
                  : capturePassed
                      ? 0
                      : 80);
          expect(channel.messages.where((m) => m['kind'] == 'cancel'), isEmpty);
          expect(channel.messages.where((m) => m['kind'] == 'delivered'),
              hasLength(mode == 'sixth-call' ? 6 : 1));
          expect(channel.messages.where((m) => m['kind'] == 'call'),
              hasLength(mode == 'sixth-call' ? 6 : 1));
          final raw = await File('${directory.path}/frontend-calls.jsonl')
              .readAsString();
          expect(raw, isNot(contains('SENTINEL')));
          final rows = raw
              .trim()
              .split('\n')
              .map((line) => jsonDecode(line) as Map)
              .toList();
          final lateFailure =
              mode == 'footer-flush-fails' || mode == 'capture-close-fails';
          // The footer can be true before late IO fails; original exit is
          // independently required, so this is never sufficient for a PASS.
          expect(rows.last['complete'],
              capturePassed || (lateFailure && !failedClose));
          expect(rows.last['originalClosed'], !failedClose);
          if (mode == 'sixth-call') expect(rows.last['calls'], 5);
          if (mode == 'normal' || mode == 'flush-held') {
            expect(
                rows
                    .where((r) => r['e'] == 'lifecycle')
                    .map((r) => [r['k'], r['o']]),
                [
                  [0, 0],
                  [1, 0],
                  [2, failedClose ? 2 : 1],
                  [3, 0]
                ]);
            expect(rows.last['lifecycle'], 4);
          }
        } finally {
          if (!channel.closeGate.isCompleted) channel.closeGate.complete();
          if (!captureFile.flushGate.isCompleted) {
            captureFile.flushGate.complete();
          }
          if (!toServer.isClosed) await toServer.close();
          await client.close();
          await toClient.close();
          await directory.delete(recursive: true);
        }
      });
    }
  }

  test(
      'interruption before diagnostic flush/finish cannot leave a completion footer',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('link-unflushed-capture-');
    late ControlledCaptureFile file;
    final capture = LinkCallCapture(
        LinkCaptureConfig(
            '12345678-1234-1234-1234-123456789abc', directory.path,
            formatVersion: 2),
        frontend: true,
        processStarted: () => '123',
        openFile: (target) async => file = ControlledCaptureFile(
            await target.open(mode: FileMode.writeOnlyAppend),
            holdFlush: true));
    await capture.start();
    capture.diagnostics.finish(capture.diagnostics.begin('open_context', {}));
    await file.flushEntered.future.timeout(const Duration(seconds: 2));
    try {
      final rows =
          (await File('${directory.path}/frontend-calls.jsonl').readAsLines())
              .map(jsonDecode)
              .toList();
      expect(rows.where((row) => row['e'] == 'capture-finished'), isEmpty);
      expect(rows.where((row) => row['e'] == 'lifecycle'), isEmpty);
      // Deliberately never call finish: a later helper cannot reconstruct it.
    } finally {
      file.flushGate.complete();
      await file.flushCompleted.future;
      await file.close();
      await directory.delete(recursive: true);
    }
  });
  for (final mode in ['off', 'on', 'observer-fails']) {
    for (final failedClose in [false, true]) {
      test(
          'attached SDK EOF automatically joins original delayed close ($mode, failure=$failedClose)',
          () async {
        final channel = EofChannel()..failClose = failedClose;
        channel.resultOverride = {
          'profileVersion': 3,
          'data': <String, dynamic>{},
          'error': null,
          'source': {'kind': 'android', 'deviceRef': 'synthetic'}
        };
        channel.resultGate.complete();
        final captured = Completer<void>();
        final calls = LinkCallDiagnostics((trace) {
          captured.complete();
          if (mode == 'observer-fails') throw StateError('synthetic observer');
        }, frontend: true);
        final port = LinkFrontendPort(
            openChannel: () => channel,
            diagnostics: mode == 'off' ? null : LinkFrontendDiagnostics(calls));
        final toServer = StreamController<List<int>>(),
            toClient = StreamController<List<int>>();
        final server = VnextMcpServer(port, profileVersion: 3);
        final client = McpClient(
            const Implementation(name: 'automatic-eof', version: '1'));
        var completed = false;
        final serving = server
            .serveTransport(LinkFrontendTransport(
                IOStreamTransport(stream: toServer.stream, sink: toClient.sink),
                port))
            .then<Object?>((_) {
          completed = true;
          return null;
        }, onError: (Object error) {
          completed = true;
          return error;
        });
        try {
          await client.connect(
              IOStreamTransport(stream: toClient.stream, sink: toServer.sink));
          final result = await client.callTool(
              const CallToolRequest(name: 'open_context', arguments: {}));
          expect(result.isError, isNot(isTrue));
          await channel.delivered.future;
          if (mode != 'off') await captured.future;
          final inputClosed = toServer.close(); // Actual original stream EOF.
          await channel.closeEntered.future.timeout(const Duration(seconds: 2));
          final original = port.close();
          expect(identical(original, port.close()), isTrue);
          // Observe a rejected original close without an unhandled future.
          final observedClose = original.then<Object?>((_) => null,
              onError: (Object error) => error);
          expect(completed, isFalse);
          expect(channel.closes, 1);
          channel.closeGate.complete();
          final outcome = await serving.timeout(const Duration(seconds: 2));
          expect(await observedClose, failedClose ? isStateError : isNull);
          expect(outcome, failedClose ? isStateError : isNull);
          await inputClosed;
          expect(channel.closes, 1);
          expect(
              channel.messages.where((message) => message['kind'] == 'cancel'),
              isEmpty);
          expect(
              channel.messages
                  .where((message) => message['kind'] == 'delivered'),
              hasLength(1));
          if (mode != 'off') expect(calls.incomplete, mode == 'observer-fails');
        } finally {
          if (!channel.closeGate.isCompleted) channel.closeGate.complete();
          if (!toServer.isClosed) await toServer.close();
          await client.close();
          await toClient.close();
        }
      });
    }
  }
  test('cancellation during attach is buffered and correlated exactly once',
      () async {
    final channel = Channel()..holdAttach = true;
    final port = LinkFrontendPort(openChannel: () => channel);
    final result = port.call('open_context', {},
        cancelled: const Stream.empty(), available: () => true, responseId: 7);
    await channel.attachEntered.future;
    port.cancelRequest(8);
    port.cancelRequest(7);
    port.cancelRequest(7);
    expect(channel.messages.where((m) => m['kind'] == 'cancel'), isEmpty);
    channel.attachGate.complete();
    await channel.callEntered.future;
    await Future<void>.delayed(Duration.zero);
    expect(
        channel.messages.map((m) => m['kind']), ['attach', 'call', 'cancel']);
    expect(channel.messages.last['id'], 1);
    channel.resultGate.complete();
    await result;
    await port.close();
  });

  test('busy contender closes its failed pipe and can try a fresh one',
      () async {
    final first = Channel()..busy = true;
    final second = Channel()..resultGate.complete();
    var opens = 0;
    final port =
        LinkFrontendPort(openChannel: () => opens++ == 0 ? first : second);
    Future<Map<String, Object?>> call(int id) => port.call('open_context', {},
        cancelled: const Stream.empty(), available: () => true, responseId: id);
    expect((await call(1))['error'], 'busy');
    expect(first.closed, isTrue);
    expect((await call(2))['error'], 'unavailable');
    expect(second.messages.where((m) => m['kind'] == 'call'), hasLength(1));
    await port.close();
  });

  for (final eof in [false, true]) {
    for (final diagnosticMode in ['off', 'on', 'throw']) {
      test(
          'real SDK $diagnosticMode diagnostics: discovery and ${eof ? 'EOF without cancellation' : 'delivery after output'}',
          () async {
        final channel = Channel();
        var opens = 0;
        final rows = <Map>[];
        final captured = [Completer<void>(), Completer<void>()];
        final calls = LinkCallDiagnostics((trace) {
          if (diagnosticMode == 'throw') {
            captured[trace.ordinal - 1].complete();
            throw StateError('SENTINEL_PRIVATE_ERROR');
          }
          rows.add(jsonDecode(trace.encode(rows.length + 1)) as Map);
          captured[trace.ordinal - 1].complete();
        }, frontend: true);
        final diagnostics =
            diagnosticMode == 'off' ? null : LinkFrontendDiagnostics(calls);
        final port = LinkFrontendPort(
            openChannel: () {
              opens++;
              return channel;
            },
            diagnostics: diagnostics);
        final toServer = StreamController<List<int>>();
        final toClient = StreamController<List<int>>();
        final protocol =
            McpServer(const Implementation(name: 'test-link', version: '1'));
        final server =
            VnextMcpServer(port, protocolServer: protocol, profileVersion: 3);
        final client = McpClient(
            const Implementation(name: 'test-client', version: '1'),
            options: const McpClientOptions(protocol: McpProtocol.require2026));
        final output =
            ObservedOutput(stream: toServer.stream, sink: toClient.sink);
        await protocol.connect(LinkFrontendTransport(output, port));
        await client.connect(
            IOStreamTransport(stream: toClient.stream, sink: toServer.sink));
        try {
          expect((await client.listTools()).tools.map((t) => t.name).toSet(),
              VnextMcpServer.schemasFor(3).keys.toSet());
          expect(opens, 0);
          final invalid = await client.callTool(const CallToolRequest(
              name: 'open_context', arguments: {'address': 'forbidden'}));
          expect(invalid.isError, isTrue);
          expect(opens, 0);
          // Client parsing may finish before the original server output future.
          // Wait for this record's original output/ack continuation, not a timer.
          if (diagnosticMode != 'off') {
            await captured[0].future.timeout(const Duration(seconds: 2));
          }
          if (diagnosticMode == 'on') {
            expect(rows, hasLength(1));
            expect(rows.single['r'], isNull);
            expect(rows.single['i'], isNull);
            expect(rows.single['u'], 1);
            expect(rows.single['x'][LinkCallStage.admission.index][0],
                LinkCallOutcome.rejected.index);
          }
          output.outputGate = eof ? null : Completer<void>();
          final call = client.callTool(
              const CallToolRequest(name: 'open_context', arguments: {}));
          // Observe the expected SDK disconnection error before closing transport.
          final observed =
              call.then<Object?>((v) => v, onError: (Object e) => e);
          await channel.callEntered.future;
          if (eof) {
            await client.close();
            await server.close();
            await observed;
            expect(channel.closed, isTrue);
            expect(
                channel.messages.where((m) => m['kind'] == 'cancel'), isEmpty);
            expect(channel.messages.where((m) => m['kind'] == 'delivered'),
                isEmpty);
          } else {
            channel.resultGate.complete();
            await output.writing.future;
            expect(channel.messages.where((m) => m['kind'] == 'delivered'),
                isEmpty);
            output.outputGate!.complete();
            await observed;
            await Future<void>.delayed(Duration.zero);
            expect(channel.messages.where((m) => m['kind'] == 'delivered'),
                hasLength(1));
          }
          if (diagnosticMode != 'off') {
            await captured[1].future.timeout(const Duration(seconds: 2));
          }
          if (diagnosticMode == 'on') {
            expect(rows, hasLength(2));
            expect(rows.last['r'], 'test-run');
            expect(rows.last['c'], 'test-connection');
            expect(rows.last['l'], 'test-lease');
            expect(rows.last['i'], 1);
            expect(rows.last['o'], isNull);
            expect(
                rows.last['x'][LinkCallStage.deliveryAck.index][0],
                (eof ? LinkCallOutcome.unknown : LinkCallOutcome.succeeded)
                    .index);
          }
          if (diagnosticMode == 'throw') expect(calls.incomplete, isTrue);
        } finally {
          await client.close();
          await server.close();
          await toServer.close();
          await toClient.close();
        }
      });
    }
  }

  for (final failure in [
    'busy',
    'attach',
    'send',
    'receive',
    'timeout',
    'result'
  ]) {
    test(
        '$failure diagnostics preserve original refusal and secret request identity remains memory-only',
        () async {
      const requestId = 'SENTINEL_EXTERNAL_REQUEST_ID';
      final channel = Channel()..resultGate.complete();
      if (failure == 'busy') channel.busy = true;
      if (failure == 'attach') channel.failReceive = 1;
      if (failure == 'send') channel.failSend = true;
      if (failure == 'receive' || failure == 'timeout') channel.failReceive = 3;
      if (failure == 'timeout') {
        channel.failure = TimeoutException('SENTINEL_PRIVATE_TIMEOUT');
      }
      if (failure == 'result') {
        channel.resultOverride = {'private': 'SENTINEL_PRIVATE_RESULT'};
      }
      final rows = <String>[];
      final calls = LinkCallDiagnostics((trace) => rows.add(trace.encode(1)),
          frontend: true);
      final diagnostics = LinkFrontendDiagnostics(calls);
      diagnostics.received({
        'method': 'tools/call',
        'id': requestId,
        'params': {
          'name': 'search_questions',
          'arguments': {
            'query': 'SENTINEL_QUERY',
            'contextRef': 'SENTINEL_CONTEXT'
          }
        }
      });
      final port = LinkFrontendPort(
          openChannel: () => channel, diagnostics: diagnostics);
      final result = await port.call(
          'search_questions', {'query': 'SENTINEL_QUERY'},
          cancelled: const Stream.empty(),
          available: () => true,
          responseId: requestId);
      expect(result['error'], failure == 'busy' ? 'busy' : 'unavailable');
      diagnostics.finish(requestId);
      await port.close();
      expect(rows.single, isNot(contains('SENTINEL')));
      final value = jsonDecode(rows.single) as Map;
      final stage = failure == 'busy' || failure == 'attach'
          ? LinkCallStage.attach
          : failure == 'send'
              ? LinkCallStage.ipcSend
              : failure == 'result'
                  ? LinkCallStage.resultValidate
                  : LinkCallStage.ipcReceive;
      expect(value['x'][stage.index][0], LinkCallOutcome.failed.index);
      if (failure == 'busy' || failure == 'attach') {
        expect(value['r'], isNull);
        expect(value['i'], isNull);
      }
    });
  }

  test(
      'duplicate external IDs and transport-only failures are unassociated, never guessed',
      () {
    final rows = <String>[];
    final calls = LinkCallDiagnostics((trace) => rows.add(trace.encode(1)),
        frontend: true);
    final diagnostics = LinkFrontendDiagnostics(calls);
    final input = {
      'id': 'SENTINEL',
      'method': 'tools/call',
      'params': {'name': 'open_context'}
    };
    diagnostics.received(input);
    diagnostics.received(input);
    calls.unbound();
    diagnostics.closed();
    expect(calls.incomplete, isTrue);
    expect(calls.unassociated, 2);
    expect(rows, hasLength(2));
    expect(rows.join(), isNot(contains('SENTINEL')));
  });
  for (final field in [
    'extra',
    'version',
    'runId',
    'connectionId',
    'id',
    'result'
  ]) {
    test(
        'original $field frame refusal is classified directly without changing public failure',
        () async {
      final channel = Channel()..resultGate.complete();
      channel.resultFrameOverrides[field] =
          field == 'version' || field == 'id' ? 999 : 'SENTINEL_PRIVATE_FRAME';
      final rows = <Map>[];
      final calls = LinkCallDiagnostics(
          (trace) => rows.add(jsonDecode(trace.encode(1)) as Map),
          frontend: true);
      final diagnostic = LinkFrontendDiagnostics(calls);
      diagnostic.received({
        'method': 'tools/call',
        'id': 17,
        'params': {'name': 'open_context', 'arguments': {}}
      });
      final port =
          LinkFrontendPort(openChannel: () => channel, diagnostics: diagnostic);
      expect(
          (await port.call('open_context', {},
              cancelled: const Stream.empty(),
              available: () => true,
              responseId: 17))['error'],
          'unavailable');
      diagnostic.finish(17);
      expect(rows.single['x'][LinkCallStage.ipcReceive.index],
          [LinkCallOutcome.rejected.index, LinkCallCause.invalidFrame.index]);
      expect(jsonEncode(rows), isNot(contains('SENTINEL')));
      await port.close();
    });
  }

  for (final bad in ['null', 'type', 'empty', 'unknown-key']) {
    test(
        'wire $bad schema rejection is captured before SDK handler without parameter leakage',
        () async {
      final toServer = StreamController<List<int>>(),
          toClient = StreamController<List<int>>();
      final captured = Completer<Map>();
      final calls = LinkCallDiagnostics(
          (trace) => captured.complete(jsonDecode(trace.encode(1)) as Map),
          frontend: true);
      var opened = false;
      final port = LinkFrontendPort(
          diagnostics: LinkFrontendDiagnostics(calls),
          openChannel: () {
            opened = true;
            return Channel();
          });
      final protocol =
          McpServer(const Implementation(name: 'schema-test', version: '1'));
      final server =
          VnextMcpServer(port, protocolServer: protocol, profileVersion: 3);
      final client =
          McpClient(const Implementation(name: 'schema-client', version: '1'));
      try {
        await protocol.connect(LinkFrontendTransport(
            IOStreamTransport(stream: toServer.stream, sink: toClient.sink),
            port));
        await client.connect(
            IOStreamTransport(stream: toClient.stream, sink: toServer.sink));
        final arguments = <String, dynamic>{
          'contextRef': 'a' * 43,
          'query': bad == 'null'
              ? null
              : bad == 'type'
                  ? 7
                  : bad == 'empty'
                      ? ''
                      : 'SENTINEL_QUERY'
        };
        if (bad == 'unknown-key') {
          arguments['SENTINEL_UNKNOWN_KEY'] = 'SENTINEL_VALUE';
        }
        toServer.add(utf8.encode('${jsonEncode({
              'jsonrpc': '2.0',
              'id': 'SENTINEL_REQUEST_ID',
              'method': 'tools/call',
              'params': {'name': 'search_questions', 'arguments': arguments}
            })}\n'));
        final row = await captured.future.timeout(const Duration(seconds: 2));
        expect(opened, isFalse);
        expect(row['r'], isNull);
        expect(row['i'], isNull);
        expect(row['x'][LinkCallStage.admission.index][0],
            LinkCallOutcome.rejected.index);
        expect(row['x'][LinkCallStage.outputSend.index][0],
            LinkCallOutcome.succeeded.index);
        expect(jsonEncode(row), isNot(contains('SENTINEL')));
        expect(row['u'], bad == 'unknown-key' ? 1 : 0);
      } finally {
        await client.close();
        await server.close();
        await toServer.close();
        await toClient.close();
      }
    });
  }
}
