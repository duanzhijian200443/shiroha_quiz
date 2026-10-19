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
  final _processCreation = <int, String?>{};
  static const fixture = 'vnext_codex_synthetic_stdio_fixture.dart';

  Future<void> connect() async {
    if (!File(executable).existsSync() ||
        p.extension(executable).toLowerCase() != '.exe') {
      fail('SHIROHA_CODEX_EXE must name an installed codex.exe.');
    }
    _processCreation.clear();
    final client = InstalledCodex(executable, Directory.current.path, home);
    _client = client;
    await client.configure(
        entrypoint: 'test/mcp/fixtures/$fixture',
        entrypointArguments: [mailbox.path]);
    await client.start();
    final inventory = await client.inventory();
    expect(inventory.containsKey('error'), isFalse);
    expect(inventory['result']['data'].single['tools'], hasLength(7));
    await _captureProcessIdentities();
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

  Future<List<File>> _pidRecords() async => (await mailbox
      .list()
      .where((entry) =>
          entry is File &&
          RegExp(r'^server-[0-9]+\.pid$').hasMatch(p.basename(entry.path)))
      .cast<File>()
      .toList());

  /// Separates process identity from liveness: the creation time captured while
  /// the server is reachable identifies the original process, so EOF cleanup can
  /// fail closed on a surviving process even when its command line is unreadable.
  /// A record already absent at connect is a previous server that exited before
  /// the test began; it cannot be the process that survives EOF.
  Future<void> _captureProcessIdentities() async {
    for (var attempt = 0; attempt < 10; attempt++) {
      final records = await _pidRecords();
      if (records.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        continue;
      }
      var live = 0;
      for (final record in records) {
        final serverPid = int.parse((await record.readAsString()).trim());
        final identity = await _queryProcess(serverPid);
        if (!identity.present) {
          _processCreation.putIfAbsent(serverPid, () => null);
          continue;
        }
        expect(identity.createdAt, isNotNull,
            reason: 'MCP server PID $serverPid creation time is unreadable.');
        if (identity.hasFixture) {
          _processCreation[serverPid] = identity.createdAt!;
          live++;
        } else if (identity.hasCommandLine) {
          // A readable command line without the fixture is an unrelated process
          // that reused the PID; the recorded server has already exited.
          _processCreation[serverPid] = null;
        } else {
          fail(
              'MCP server PID $serverPid command line is unreadable at connect.');
        }
      }
      if (live > 0) return;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    fail('No live synthetic MCP server identity observed at connect.');
  }

  Future<
      ({
        bool present,
        String? createdAt,
        bool hasFixture,
        bool hasCommandLine
      })> _queryProcess(int serverPid) async {
    final status = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      "\$p = Get-CimInstance Win32_Process -Filter 'ProcessId=$serverPid'; "
          "if (\$null -eq \$p) { '{\"state\":\"absent\"}' } else { "
          "\$created = if (\$null -eq \$p.CreationDate) { \$null } else { "
          "\$p.CreationDate.ToUniversalTime().ToString('o') }; "
          "\$hasLine = \$null -ne \$p.CommandLine; "
          "\$has = \$hasLine -and \$p.CommandLine.Contains('$fixture'); "
          "@{ state='present'; createdAt=\$created; hasFixture=\$has; "
          'hasCommandLine=\$hasLine } | ConvertTo-Json -Compress }',
    ]);
    expect(status.exitCode, 0,
        reason: 'Process identity query failed for PID $serverPid.');
    expect((status.stderr as String).trim(), isEmpty,
        reason: 'Process identity query wrote diagnostics for PID $serverPid.');
    final decoded = jsonDecode((status.stdout as String).trim());
    if (decoded is! Map) {
      fail('Unreadable process identity for PID $serverPid.');
    }
    final state = decoded['state'];
    if (state == 'absent') {
      return (
        present: false,
        createdAt: null,
        hasFixture: false,
        hasCommandLine: false
      );
    }
    if (state != 'present') {
      fail('Unreadable process identity state for PID $serverPid.');
    }
    final createdAt = decoded['createdAt'];
    return (
      present: true,
      createdAt: createdAt is String && createdAt.isNotEmpty ? createdAt : null,
      hasFixture: decoded['hasFixture'] == true,
      hasCommandLine: decoded['hasCommandLine'] == true,
    );
  }

  Future<void> _awaitCapturedExit(int serverPid, String captured) async {
    for (var attempt = 0; attempt < 25; attempt++) {
      final identity = await _queryProcess(serverPid);
      if (!identity.present) return;
      expect(identity.createdAt, isNotNull,
          reason: 'Cannot confirm whether MCP server PID $serverPid exited.');
      if (identity.createdAt != captured) return;
      if (attempt == 24) {
        fail('Owned MCP process $serverPid must close on Codex EOF.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  Future<void> _awaitUncapturedExit(int serverPid) async {
    for (var attempt = 0; attempt < 25; attempt++) {
      final identity = await _queryProcess(serverPid);
      if (!identity.present) return;
      if (identity.hasCommandLine && !identity.hasFixture) return;
      expect(identity.hasCommandLine, isTrue,
          reason: 'MCP server PID $serverPid command line is unreadable.');
      if (attempt == 24) {
        fail('MCP server PID $serverPid is still running after Codex EOF.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  Future<void> disconnect() async {
    final client = _client;
    if (client == null) return;
    _client = null;
    expect(await client.rpc.close(), 0);
    expect(client.rpc.forcedClose, isFalse);
    expect(client.rpc.protocolClean, isTrue);
    final records = await _pidRecords();
    expect(records, isNotEmpty, reason: 'Expected a recorded MCP server PID.');
    for (final record in records) {
      final serverPid = int.parse((await record.readAsString()).trim());
      final captured = _processCreation[serverPid];
      if (captured == null) {
        await _awaitUncapturedExit(serverPid);
      } else {
        await _awaitCapturedExit(serverPid, captured);
      }
      await record.delete();
    }
    _processCreation.clear();
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
