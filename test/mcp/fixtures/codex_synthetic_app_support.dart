// Parent side of the TEST-ONLY mailbox. The existing App composition owns
// authentication, approval, persistence and release. No business result is faked.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/mcp/vnext_mcp_composition_root.dart';

final class CodexSyntheticAppLink {
  CodexSyntheticAppLink(this.directory, this.composition);
  final Directory directory;
  final VnextMcpAppComposition Function() composition;
  final _seen = <String>{};
  final _pending = <Future<void>>{};
  bool _closed = false;
  late Future<void> _loop;
  int stageCalls = 0;
  bool dropStageResponse = false;
  final dropped = Completer<void>();

  void start() => _loop = _listen();

  Future<void> _listen() async {
    while (!_closed) {
      await for (final entry in directory.list()) {
        if (entry is! File ||
            !entry.path.endsWith('.request') ||
            !_seen.add(entry.path)) {
          continue;
        }
        final work = _dispatch(entry);
        _pending.add(work);
        unawaited(work.whenComplete(() => _pending.remove(work)));
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<void> _dispatch(File request) async {
    final base = p.withoutExtension(request.path);
    // A closed/unavailable App can return without listening. Broadcast close
    // must still settle, otherwise teardown waits forever on that refusal.
    final cancelled = StreamController<void>.broadcast();
    final cancel = File('$base.cancel');
    final poll = Timer.periodic(const Duration(milliseconds: 10), (_) {
      if (_closed || cancel.existsSync()) {
        if (!cancelled.isClosed) cancelled.add(null);
      }
    });
    try {
      final input = (jsonDecode(await request.readAsString()) as Map);
      final tool = input['tool'] as String;
      if (tool == 'propose_generated_questions') stageCalls++;
      final result = await composition().call(
          tool, (input['arguments'] as Map).cast<String, dynamic>(),
          cancelled: cancelled.stream,
          available: () => !_closed && !cancel.existsSync());
      if (tool == 'propose_generated_questions' && dropStageResponse) {
        dropStageResponse = false;
        // Prove actual persistence before deliberately dropping ONLY delivery.
        // No substituted success/error body and no second stage invocation.
        if (!dropped.isCompleted) dropped.complete();
        return;
      }
      if (!_closed && !cancel.existsSync()) {
        final temp = File('$base.replying');
        await temp.writeAsString(jsonEncode(result));
        await temp.rename('$base.response');
      }
    } finally {
      poll.cancel();
      await cancelled.close();
    }
  }

  Future<void> close() async {
    _closed = true;
    await _loop;
    await Future.wait(_pending.toList());
  }
}
