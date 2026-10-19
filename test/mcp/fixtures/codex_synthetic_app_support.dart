// Parent side of the TEST-ONLY mailbox. The existing App composition owns
// authentication, approval, persistence and release. No business result is faked.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_composition_root.dart';
import 'codex_app_server_support.dart';

/// Installed-client driver shared by synthetic App compositions. The client
/// receives only the existing disposable mailbox, never App authority or SQLite.
final class CodexSyntheticClient {
  CodexSyntheticClient(this.executable, this.home, this.mailbox);
  final String executable;
  final Directory home, mailbox;
  InstalledCodex? _client;
  static const fixture = 'vnext_codex_synthetic_stdio_fixture.dart';

  Future<void> connect() async {
    if (!File(executable).existsSync() ||
        p.extension(executable).toLowerCase() != '.exe') {
      fail('SHIROHA_CODEX_EXE must name an installed codex.exe.');
    }
    final client = InstalledCodex(executable, Directory.current.path, home);
    _client = client;
    await client.configure(
        entrypoint: 'test/mcp/fixtures/$fixture',
        entrypointArguments: [mailbox.path]);
    await client.start();
    final inventory = await client.inventory();
    expect(inventory.containsKey('error'), isFalse);
    expect(inventory['result']['data'].single['tools'], hasLength(7));
  }

  Future<Map<String, dynamic>> call(String tool,
      [Map<String, dynamic> arguments = const {}]) async {
    final response = await _client!.call(tool, arguments);
    expect(response.containsKey('error'), isFalse);
    final result = response['result'] as Map;
    final envelope =
        (result['structuredContent'] as Map).cast<String, dynamic>();
    expect(envelope.keys.toSet(), {'profileVersion', 'data', 'error'});
    expect(envelope['profileVersion'], 2);
    expect(jsonDecode(result['content'].single['text'] as String), envelope);
    expect(result['isError'] ?? false, envelope['error'] != null);
    return envelope;
  }

  Future<void> disconnect() async {
    final client = _client;
    if (client == null) return;
    _client = null;
    expect(await client.rpc.close(), 0);
    expect(client.rpc.forcedClose, isFalse);
    expect(client.rpc.protocolClean, isTrue);
    final records = await mailbox
        .list()
        .where((entry) =>
            entry is File &&
            RegExp(r'^server-[0-9]+\.pid$').hasMatch(p.basename(entry.path)))
        .cast<File>()
        .toList();
    expect(records, isNotEmpty);
    for (final record in records) {
      final serverPid = int.parse(await record.readAsString());
      final status = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        "(Get-CimInstance Win32_Process -Filter 'ProcessId=$serverPid')"
            '.CommandLine',
      ]);
      expect(status.exitCode, 0);
      expect((status.stderr as String).trim(), isEmpty);
      expect((status.stdout as String).contains(fixture), isFalse,
          reason: 'Owned MCP process must close on Codex EOF.');
      await record.delete();
    }
  }
}

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
