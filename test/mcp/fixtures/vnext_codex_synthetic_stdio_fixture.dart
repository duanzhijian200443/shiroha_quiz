// Test-only file mailbox to the Flutter test's existing App composition.
// Codex owns the MCP stdio connection. No private notifications, sockets,
// authentication, database access or production entrypoint option live here.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:mcp_dart/mcp_dart.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_server.dart';
import 'stage_cancellation_evidence.dart';

final class SyntheticMailboxPort implements VnextMcpPort {
  SyntheticMailboxPort(this.directory, {this.stageWait = false, this.evidence});
  final Directory directory;
  final bool stageWait;
  final StageCancellationEvidence? evidence;
  bool _closed = false;
  int _next = 0;
  final _pending = <Future<void>>{};

  @override
  Future<Map<String, Object?>> call(String tool, Map<String, dynamic> arguments,
      {required Stream<void> cancelled,
      required bool Function() available}) async {
    if (_closed || !available()) return vnextFailure('unavailable');
    if (_pending.length >= 16) return vnextFailure('busy');
    final done = Completer<void>();
    _pending.add(done.future);
    final id = ++_next;
    final base = p.join(directory.path, '$pid-$id');
    final request = File('$base.request');
    final response = File('$base.response');
    final cancel = File('$base.cancel');
    final trace = tool == 'propose_generated_questions' ? evidence : null;
    trace?.mark(StageCancellationPhase.mailboxStarted);
    var aborted = false;
    final subscription = cancelled.listen((_) {
      trace?.mark(StageCancellationPhase.sdkAbort);
      aborted = true;
    });
    final deadline = Stopwatch()..start();
    bool stopped() =>
        _closed ||
        aborted ||
        !available() ||
        File(p.join(directory.path, 'closed')).existsSync();
    final limit = stageWait && tool == 'propose_generated_questions'
        ? const Duration(seconds: 150)
        : const Duration(seconds: 8);
    bool expired() => deadline.elapsed >= limit;
    Future<void> poll() =>
        Future<void>.delayed(const Duration(milliseconds: 10));
    try {
      // Rename publishes only complete JSON; all payloads are synthetic and
      // task-owned. Files are never a durable business journal or retry queue.
      // A transient local lock is not an App outcome: retry only this
      // disposable exchange within the same deadline, never the App call.
      final temp = File('$base.writing');
      final payload = jsonEncode({'tool': tool, 'arguments': arguments});
      while (true) {
        try {
          await temp.writeAsString(payload);
          await temp.rename(request.path);
          break;
        } on FileSystemException {
          if (stopped() || expired()) return vnextFailure('outcome_unknown');
          await poll();
        }
      }
      while (!stopped() && !expired()) {
        try {
          if (await response.exists()) {
            trace?.mark(StageCancellationPhase.mailboxResponse);
            return (jsonDecode(await response.readAsString()) as Map)
                .cast<String, Object?>();
          }
        } on FileSystemException {
          // Locked while another process finishes writing; keep polling.
        } on FormatException {
          // A transient incomplete local read is not an App outcome.
        }
        // Poll only the disposable test link, never retry the owning App call.
        await poll();
      }
      if (expired()) trace?.mark(StageCancellationPhase.mailboxExpired);
      if (!available()) trace?.mark(StageCancellationPhase.mailboxUnavailable);
      if (File(p.join(directory.path, 'closed')).existsSync()) {
        trace?.mark(StageCancellationPhase.mailboxPeerClosed);
      }
      return vnextFailure('outcome_unknown');
    } catch (_) {
      return vnextFailure('outcome_unknown');
    } finally {
      await cancel.writeAsString('closed');
      trace?.mark(StageCancellationPhase.cancelWritten);
      await subscription.cancel();
      done.complete();
      _pending.remove(done.future);
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    await Future.wait(_pending.toList());
  }
}

Future<void> main(List<String> arguments) async {
  final directory = Directory(arguments.first);
  final stageWait = arguments.length == 2 && arguments[1] == 'stage-wait';
  if (arguments.length != (stageWait ? 2 : 1)) {
    throw ArgumentError('Invalid test fixture options.');
  }
  await File(p.join(directory.path, 'server-$pid.pid')).writeAsString('$pid');
  if (!stageWait) {
    await VnextMcpServer(SyntheticMailboxPort(directory)).serveStdio();
    return;
  }
  final evidence = StageCancellationEvidence(directory: directory);
  // Existing protocolServer seam; the same VnextMcpServer registers all tools
  // and owns extra.signal. This adds an input observer, no new tool/business path.
  final protocol = McpServer(
      const Implementation(name: 'shiroha_mcp_vnext', version: '0.2.0'),
      options: const McpServerOptions(
          capabilities: ServerCapabilities(tools: ServerCapabilitiesTools())));
  VnextMcpServer(
      SyntheticMailboxPort(directory, stageWait: true, evidence: evidence),
      protocolServer: protocol);
  await protocol.connect(StageObservedStdio(evidence));
}
