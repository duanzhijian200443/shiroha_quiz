// Test-only file mailbox to the Flutter test's existing App composition.
// Codex owns the MCP stdio connection. No private notifications, sockets,
// authentication, database access or production entrypoint option live here.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/mcp/vnext_mcp_server.dart';

final class SyntheticMailboxPort implements VnextMcpPort {
  SyntheticMailboxPort(this.directory);
  final Directory directory;
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
    var aborted = false;
    final subscription = cancelled.listen((_) => aborted = true);
    final deadline = Stopwatch()..start();
    try {
      // Rename publishes only complete JSON; all payloads are synthetic and
      // task-owned. Files are never a durable business journal or retry queue.
      final temp = File('$base.writing');
      await temp
          .writeAsString(jsonEncode({'tool': tool, 'arguments': arguments}));
      await temp.rename(request.path);
      while (!_closed &&
          !aborted &&
          available() &&
          deadline.elapsed < const Duration(seconds: 8)) {
        if (await response.exists()) {
          return (jsonDecode(await response.readAsString()) as Map)
              .cast<String, Object?>();
        }
        // Poll only the disposable test link, never retry the owning App call.
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      return vnextFailure('outcome_unknown');
    } catch (_) {
      return vnextFailure('outcome_unknown');
    } finally {
      await cancel.writeAsString('closed');
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
  final directory = Directory(arguments.single);
  await File(p.join(directory.path, 'server-$pid.pid')).writeAsString('$pid');
  await VnextMcpServer(SyntheticMailboxPort(directory)).serveStdio();
}
