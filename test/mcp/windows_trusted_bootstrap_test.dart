// Real compiled Bridge/Codex processes; Fake Native/TLS, public vectors and
// temporary SQLite only. No mailbox dispatch or substituted authentication.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/application/backup/backup_restore_coordinator.dart';
import 'package:shiroha_quiz/application/generated_question/generated_question_service.dart';
import 'package:shiroha_quiz/data/external/windows_tls_transport.dart';
import 'package:shiroha_quiz/data/external/windows_codex_client.dart';
import 'package:shiroha_quiz/data/repositories/backup_database_authority.dart';
import 'package:shiroha_quiz/data/repositories/backup_snapshot_repository.dart';
import 'package:shiroha_quiz/services/backup/backup_disk_space.dart';
import 'package:shiroha_quiz/services/backup/backup_restore_runtime.dart';
import 'package:shiroha_quiz/services/file_library/managed_file_storage_adapter.dart';

import '../application/generated_question/generated_test_support.dart';
import '../application/study_query/study_query_test_support.dart'
    show insertLegacyQuestion;
import 'fixtures/codex_app_server_support.dart';
import 'fixtures/windows_app_transport_fixture.dart';
import 'fixtures/windows_process_channel.dart';

final class _Disk implements BackupDiskSpaceProbe {
  @override
  Future<int?> availableBytes(String path) async => 1 << 40;
}

final class _ExitObservation {
  _ExitObservation(this.process)
      : lines = StreamIterator(process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())),
        errors = process.stderr.drain<void>();
  final Process process;
  final StreamIterator<String> lines;
  final Future<void> errors;

  static Future<_ExitObservation> capture(Directory session) async {
    final childPid = int.parse(p.basename(session.path).substring(8));
    // Use the task's installed PowerShell 7 runtime; legacy Windows PowerShell
    // forbids script-file execution here. No execution policy is changed.
    final result = _ExitObservation(await Process.start('pwsh.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-File',
      p.absolute('test/mcp/fixtures/windows_process_exit_observer.ps1'),
      '-TargetPid',
      '$childPid'
    ]));
    expect(await result.lines.moveNext(), isTrue);
    expect(jsonDecode(result.lines.current)['observed'], isTrue);
    return result;
  }

  Future<void> report() async {
    final result = await observe();
    printOnFailure('original compiled Bridge process: $result');
    expect(result['exited'], isTrue);
    expect(result['exitCode'], 0);
  }

  Future<Map<String, dynamic>> observe() async {
    expect(await lines.moveNext(), isTrue);
    final result = (jsonDecode(lines.current) as Map).cast<String, dynamic>();
    expect(await process.exitCode, 0);
    await lines.cancel();
    await errors;
    return result;
  }
}

/// Only the existing raw-channel seam crosses processes. App's original
/// WindowsTlsHost performs P15 authentication and P8/P10 business dispatch.
final class _RawLink {
  _RawLink(this.root, this.app);
  final Directory root;
  final WindowsAppTransportFixture app;
  final channels = <ProcessTestChannel>[];
  final seen = <String>{};
  bool stopped = false;
  late Future<void> running;
  void start() => running = _run();
  Future<void> _run() async {
    while (!stopped) {
      await for (final session in root.list()) {
        if (session is! Directory ||
            !p.basename(session.path).startsWith('session-')) {
          continue;
        }
        await for (final file in session.list()) {
          final name = p.basename(file.path);
          if (file is! File ||
              !RegExp(r'^connect-\d+$').hasMatch(name) ||
              !seen.add(file.path)) {
            continue;
          }
          final number = int.parse(name.substring(8));
          final channel = ProcessTestChannel(
              session, 'server-$number', 'client-$number', app.clientDer!);
          channels.add(channel);
          if (app.host.phase == WindowsTlsHostPhase.ready) {
            app.listener.controller.add(ProcessTestRawPeer(channel));
          } else {
            // Fake TLS models a closed listener as peer EOF, never an App reply.
            await channel.close();
          }
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<void> close() async {
    stopped = true;
    await running;
    await Future.wait(channels.map((c) => c.close()));
  }

  Future<void> disconnectSession(Directory session) => Future.wait(channels
      .where((channel) => channel.root.path == session.path)
      .map((channel) => channel.close())).then((_) {});
}

Map<String, dynamic> _data(Map<String, dynamic> response) {
  expect(response['error'], isNull);
  final result = (response['result'] as Map)['structuredContent'] as Map;
  expect(result['error'], isNull);
  return (result['data'] as Map).cast<String, dynamic>();
}

Future<void> _waitFor(bool Function() predicate, String boundary) async {
  final watch = Stopwatch()..start();
  while (!predicate()) {
    if (watch.elapsed > const Duration(seconds: 15)) {
      fail('isolated condition timed out: $boundary');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<JsonLineProcess> _rawClient(String binary, Directory root) async {
  final rpc = await JsonLineProcess.start(binary, [root.path],
      cwd: Directory.current.path, home: root.path);
  final init = await rpc.request(
      'initialize',
      {
        'protocolVersion': '2025-06-18',
        'capabilities': <String, Object?>{},
        'clientInfo': {'name': 'isolated-lifecycle', 'version': '1'}
      },
      mcp: true);
  expect(init['error'], isNull);
  rpc.send({'jsonrpc': '2.0', 'method': 'notifications/initialized'});
  return rpc;
}

Future<Map<String, dynamic>> _rawCall(JsonLineProcess rpc, String tool,
        [Map<String, dynamic> arguments = const {}]) =>
    rpc.request('tools/call', {'name': tool, 'arguments': arguments},
        mcp: true);

Future<String> _rawContext(JsonLineProcess rpc) async {
  final targets = _data(await _rawCall(rpc, 'open_generation_context'));
  return _data(await _rawCall(rpc, 'open_generation_context', {
    'targetRef': (targets['items'] as List).first['targetRef']
  }))['contextRef'] as String;
}

Future<void> _restore(WindowsAppTransportFixture app) async {
  final snapshots =
      BackupSnapshotRepository(databaseHelper: app.files.s.h.helper);
  final backup = BackupRestoreCoordinator(
      operations: BackupRestoreRuntime(
          databaseAuthority: SqliteBackupDatabaseAuthority(
              beforeClose: app.integration.close,
              databaseHelper: app.files.s.h.helper,
              snapshotRepository: snapshots),
          snapshotRepository: snapshots,
          managedFileStorage:
              ManagedFileStorageAdapter(managedRoot: app.files.managed),
          restoreRoot: Directory(p.join(app.files.s.h.temp.path, 'restore')),
          managedFilesRoot: app.files.managed,
          diskSpaceProbe: _Disk()));
  final archive = p.join(app.files.s.h.temp.path, 'compiled.zip');
  await backup.exportTo(archive);
  await backup.prepareRestore(archive);
  await backup.commitPreparedRestore();
}

void main() {
  initializeGeneratedTests();
  final codex = Platform.environment['SHIROHA_CODEX_EXE'];
  group('isolated compiled trusted bootstrap', () {
    late Directory root;
    late String binary;
    late WindowsAppTransportFixture app;
    late _RawLink link;
    late Directory buildRoot;
    late Directory parent;
    late String compiled;
    late String hostedProbe;
    setUpAll(() async {
      parent = await Directory(p.absolute('.dart_tool/ar-r6b-bootstrap-tests'))
          .create(recursive: true);
      buildRoot = await parent.createTemp('build-');
      compiled = p.join(buildRoot.path, 'isolated_bridge.exe');
      final result = await Process.run(flutterDartExecutable(), [
        'compile',
        'exe',
        'test/mcp/fixtures/windows_trusted_bootstrap_aot.dart',
        '-o',
        compiled
      ]);
      expect(result.exitCode, 0,
          reason: 'Compile isolated product bootstrap: ${result.stderr}');
      hostedProbe = p.join(buildRoot.path, 'hosted_probe.exe');
      final hostedBuild = await Process.run(flutterDartExecutable(), [
        'compile',
        'exe',
        'test/mcp/fixtures/windows_bridge_aot_probe.dart',
        '-o',
        hostedProbe
      ]);
      expect(hostedBuild.exitCode, 0,
          reason: 'Compile original hosted custody');
    });
    tearDownAll(() => buildRoot.delete(recursive: true));
    setUp(() async {
      root = await parent.createTemp('compiled-');
      binary = p.join(root.path, 'isolated_bridge.exe');
      await File(compiled).copy(binary);
      app = WindowsAppTransportFixture();
      await app.open(productBridge: true, protectedAcquisition: true);
      await app.bridge.close();
      final d = app.bridgeDependencies;
      final material = app.pairing.native.service.validatedPublicMaterial();
      await File(p.join(root.path, 'isolated-bootstrap'))
          .writeAsString('public-fake-security-only');
      await File(p.join(root.path, 'public-material.json'))
          .writeAsString(jsonEncode({
        'security': 'fake-only',
        'issuer': base64Encode(material.issuerCertificateDer),
        'client': base64Encode(app.clientDer!),
        'server': base64Encode(material.serverLeafDer!),
        'serverDigest': base64Encode(d.trusted.serverLeafDigest),
        'installation': material.installationId,
        'epoch': d.trusted.verifiedEpochHighWater.toString(),
        'now': app.pairing.native.now.toIso8601String(),
        'discovery': [
          for (final e in app.pairing.native.calls.discoveryFiles.entries)
            [e.key, base64Encode(e.value)]
        ]
      }));
      link = _RawLink(root, app)..start();
    });
    tearDown(() async {
      final sessions = root
          .listSync()
          .whereType<Directory>()
          .where((d) => p.basename(d.path).startsWith('session-'));
      for (final session in sessions) {
        // Safe diagnostic stages only, never material or raw business frames.
        printOnFailure(
            'compiled lifecycle: closeEntered=${File(p.join(session.path, 'close-entered')).existsSync()} '
            'ownerClosed=${File(p.join(session.path, 'owner-closed')).existsSync()} '
            'entrySettled=${File(p.join(session.path, 'settled')).existsSync()}');
      }
      await link.close();
      await app.close();
      try {
        await root.delete(recursive: true);
      } on FileSystemException {
        final observation = await Process.run('pwsh.exe', [
          '-NoProfile',
          '-NonInteractive',
          '-File',
          p.absolute('test/mcp/fixtures/windows_sharing_observer.ps1'),
          '-TargetFile',
          binary
        ]);
        printOnFailure(
            'task executable sharing observer: ${observation.stdout}');
        rethrow;
      }
    });

    test('direct original stdin EOF waits for compiled Owner settlement',
        () async {
      final rpc = await JsonLineProcess.start(binary, [root.path],
          cwd: Directory.current.path, home: root.path);
      final init = await rpc.request(
          'initialize',
          {
            'protocolVersion': '2025-06-18',
            'capabilities': <String, Object?>{},
            'clientInfo': {'name': 'isolated-eof', 'version': '1'}
          },
          mcp: true);
      expect(init['error'], isNull);
      rpc.send({'jsonrpc': '2.0', 'method': 'notifications/initialized'});
      expect(await rpc.close(), 0);
      expect(rpc.forcedClose, isFalse);
      final session = root
          .listSync()
          .whereType<Directory>()
          .singleWhere((d) => p.basename(d.path).startsWith('session-'));
      expect(File(p.join(session.path, 'close-entered')).existsSync(), isTrue);
      expect(File(p.join(session.path, 'owner-closed')).existsSync(), isTrue);
      expect(File(p.join(session.path, 'settled')).existsSync(), isTrue);
    });

    for (final boundary in ['client EOF', 'crash', 'App shutdown', 'Restore']) {
      test('compiled pending STAGE fails closed on $boundary', () async {
        final rpc = await _rawClient(binary, root);
        final session =
            Directory(p.join(root.path, 'session-${rpc.process.pid}'));
        try {
          final context = await _rawContext(rpc);
          final staged = _rawCall(rpc, 'propose_generated_questions', {
            'contextRef': context,
            'submission': jsonDecode(submission(key: 'compiled-boundary'))
          });
          final outcome = staged.then<Object>((value) => value,
              onError: (Object error, StackTrace _) => error);
          await _waitFor(
              () => app.approval.waitingForUser, 'boundary approval');
          final original = app.approvalView.pending!;
          switch (boundary) {
            case 'client EOF':
              expect(await rpc.close(), 0);
            case 'crash':
              await File(p.join(session.path, 'crash')).writeAsString('crash');
              expect(await rpc.process.exitCode, 23);
              expect(await rpc.close(), 23);
              await link.disconnectSession(session);
              expect(File(p.join(session.path, 'owner-closed')).existsSync(),
                  isFalse);
              expect(
                  File(p.join(session.path, 'settled')).existsSync(), isFalse);
            case 'App shutdown':
              await app.startup.close();
            case 'Restore':
              await _restore(app);
          }
          final result = await outcome;
          if (boundary == 'client EOF' || boundary == 'crash') {
            expect(result, isA<StateError>());
          } else {
            expect((result as Map)['result']['structuredContent']['error'],
                isNotNull);
          }
          await app.host.whenConnectionsSettled;
          expect(app.approval.pendingCount, 0);
          await expectLater(
              app.approvalView.confirm(original), throwsA(anything));
          expect(
              await (await app.files.s.h.helper.database)
                  .query('generated_question_proposals'),
              isEmpty);
          expect(rpc.forcedClose, isFalse);
          if (boundary == 'client EOF') {
            expect(File(p.join(session.path, 'settled')).existsSync(), isTrue);
          }
          if (boundary == 'client EOF' || boundary == 'crash') {
            final restarted = await _rawClient(binary, root);
            try {
              final revalidated = await _rawCall(restarted,
                  'open_generation_context', {'contextRef': context});
              // P4/P8 allow same-Principal READ revalidation. The new
              // execution still needs a fresh exact-Session approval below.
              expect(_data(revalidated)['items'], isA<List>());
              final fresh = await _rawContext(restarted);
              final pending =
                  _rawCall(restarted, 'propose_generated_questions', {
                'contextRef': fresh,
                'submission': jsonDecode(submission(key: 'compiled-boundary'))
              }).then<Object>((value) => value,
                      onError: (Object error, StackTrace _) => error);
              await _waitFor(() => app.approval.waitingForUser,
                  'fresh approval after process restart');
              expect(identical(app.approvalView.pending, original), isFalse);
              expect(
                  await app.files.s.h.count('generated_question_proposals'), 0);
              expect(await restarted.close(), 0);
              expect(await pending, isA<StateError>());
              await app.host.whenConnectionsSettled;
              expect(app.approval.pendingCount, 0);
              expect(restarted.forcedClose, isFalse);
            } finally {
              await restarted.close();
            }
          }
          if (boundary == 'App shutdown' || boundary == 'Restore') {
            final refused = await _rawCall(
                rpc, 'open_generation_context', {'contextRef': context});
            expect(refused['result']['structuredContent']['error'], isNotNull);
          }
        } finally {
          await rpc.close();
        }
      }, timeout: const Timeout(Duration(minutes: 2)));
    }

    for (final mode in WindowsCodexConnectionMode.values) {
      test('selected client lifecycle qualification ${mode.name}', () async {
        final selection = await WindowsCodexClientSelection.inspect(
            executable: WindowsCodexExecutableFile(codex!),
            use: WindowsCodexClientUse.product,
            mode: mode);
        // Even a clean observation cannot promote an unaccepted build or patch.
        await expectLater(selection.claim(mode), throwsStateError);
        var command = binary;
        var args = [root.path];
        if (mode == WindowsCodexConnectionMode.hosted) {
          await File(binary).copy(p.join(root.path, 'shiroha_bridge.exe'));
          final package = Platform.environment['SHIROHA_BRIDGE_PACKAGE'];
          expect(package, isNotNull,
              reason: 'Explicit formal package required');
          await File(p.join(package!, 'shiroha_external_native.dll'))
              .copy(p.join(root.path, 'shiroha_external_native.dll'));
          command = p.join(root.path, 'hosted_probe.exe');
          await File(hostedProbe).copy(command);
          args = ['stdio'];
        }
        final home = await root.createTemp('qualification-');
        final client = InstalledCodex(codex, Directory.current.path, home);
        await client.configure(command: command, commandArguments: args);
        _ExitObservation? observer;
        late Directory session;
        Map<String, dynamic>? exit;
        var inventoryTools = -1;
        var extraLaunches = -1;
        try {
          await client.start();
          expect(
              _data(await client.call('open_generation_context', {}))['items'],
              isNotEmpty);
          session = root
              .listSync()
              .whereType<Directory>()
              .singleWhere((d) => p.basename(d.path).startsWith('session-'));
          observer = await _ExitObservation.capture(session);
          int launches() => root
              .listSync()
              .whereType<File>()
              .where((f) => p.basename(f.path).startsWith('launch-'))
              .length;
          final before = launches();
          final inventory = await client.inventory();
          inventoryTools = ((inventory['result']?['data'] as List?)
                      ?.firstOrNull?['tools'] as Map?)
                  ?.length ??
              0;
          extraLaunches = launches() - before;
          // Inventory must never destroy the original business connection.
          expect(
              _data(await client.call('open_generation_context', {}))['items'],
              isNotEmpty);
        } finally {
          expect(await client.rpc.close(), 0);
          expect(client.rpc.forcedClose, isFalse);
          expect(client.rpc.protocolClean, isTrue);
          if (observer != null) exit = await observer.observe();
        }
        bool receipt(String name) =>
            File(p.join(session.path, name)).existsSync();
        final clean = exit?['exitCode'] == 0 &&
            receipt('close-entered') &&
            receipt('owner-closed') &&
            receipt('settled');
        // Safe, durable test-run evidence; no paths, credentials or payloads.
        stdout.writeln('CLIENT_QUALIFICATION ${jsonEncode({
              'digest': selection.digest,
              'mode': mode.name,
              'bridgeExit': exit?['exitCode'],
              'closeEntered': receipt('close-entered'),
              'ownerClosed': receipt('owner-closed'),
              'settled': receipt('settled'),
              'liveInventoryTools': inventoryTools,
              'extraLaunches': extraLaunches,
              'originalLifecycleClean': clean,
              'productSupported': false,
            })}');
        if (selection.support ==
            WindowsCodexClientSupport.isolatedValidationOnly) {
          expect(clean, isTrue);
          // Explicit second connection after original settlement, never a
          // recovery retry for an unsupported/unknown client outcome.
          final reconnectHome =
              await root.createTemp('qualification-reconnect-');
          final reconnected =
              InstalledCodex(codex, Directory.current.path, reconnectHome);
          await reconnected.configure(command: command, commandArguments: args);
          _ExitObservation? restartedExit;
          try {
            await reconnected.start();
            expect(
                _data(await reconnected.call('open_generation_context', {}))[
                    'items'],
                isNotEmpty);
            final restartedSession = root
                .listSync()
                .whereType<Directory>()
                .singleWhere((d) =>
                    p.basename(d.path).startsWith('session-') &&
                    !File(p.join(d.path, 'settled')).existsSync());
            expect(restartedSession.path, isNot(session.path));
            restartedExit = await _ExitObservation.capture(restartedSession);
          } finally {
            expect(await reconnected.rpc.close(), 0);
            expect(reconnected.rpc.forcedClose, isFalse);
            expect(reconnected.rpc.protocolClean, isTrue);
            if (restartedExit != null) await restartedExit.report();
          }
          for (final d in root
              .listSync()
              .whereType<Directory>()
              .where((d) => p.basename(d.path).startsWith('session-'))) {
            expect(File(p.join(d.path, 'owner-closed')).existsSync(), isTrue);
            expect(File(p.join(d.path, 'settled')).existsSync(), isTrue);
          }
        }
      },
          skip: codex == null ? 'Client not selected' : false,
          timeout: const Timeout(Duration(minutes: 3)));
    }

    test('selected Codex seven tools, Review, original key, reconnect and B0',
        () async {
      await insertLegacyQuestion(app.files.s.h.db,
          id: 'compiled-question',
          bankName: 'bank',
          createdAt: 1,
          content: 'Synthetic needle');
      InstalledCodex? active;
      Future<InstalledCodex> connect() async {
        final home = await root.createTemp('codex-');
        final c = InstalledCodex(codex!, Directory.current.path, home);
        await c.configure(command: binary, commandArguments: [root.path]);
        active = c;
        final selected = await WindowsCodexClientSelection.inspect(
            executable: WindowsCodexExecutableFile(codex),
            use: WindowsCodexClientUse.isolatedValidation,
            mode: WindowsCodexConnectionMode.direct);
        // Status discovery creates a temporary MCP manager. Settle it before
        // starting the business thread instead of racing two credential Owners.
        await c.start(createThread: false);
        final hold = File(p.join(root.path, 'observe-discovery'));
        await hold.writeAsString('observe-original');
        final seen =
            root.listSync().whereType<Directory>().map((d) => d.path).toSet();
        _ExitObservation? discoveryExit;
        await selected.discoverBeforeBusiness(discover: () async {
          final inventory = c.inventory();
          Directory? launched;
          await _waitFor(() {
            final fresh = root.listSync().whereType<Directory>().where((d) =>
                !seen.contains(d.path) &&
                p.basename(d.path).startsWith('session-') &&
                File(p.join(d.path, 'ready')).existsSync());
            if (fresh.isEmpty) return false;
            launched = fresh.single;
            return true;
          }, 'original discovery process ready');
          discoveryExit = await _ExitObservation.capture(launched!);
          await File(p.join(launched!.path, 'observed')).writeAsString('bound');
          expect((await inventory)['result']['data'].single['tools'],
              hasLength(7));
        }, settleOriginal: () async {
          if (discoveryExit == null) throw StateError('Discovery exit unknown');
          await discoveryExit!.report();
          for (final session in root
              .listSync()
              .whereType<Directory>()
              .where((d) => p.basename(d.path).startsWith('session-'))) {
            await _waitFor(
                () => File(p.join(session.path, 'settled')).existsSync(),
                'Codex discovery process settlement before business launch');
          }
        });
        await hold.delete();
        await selected.claim(WindowsCodexConnectionMode.direct);
        await c.newThread();
        return c;
      }

      Future<void> disconnect() async {
        final c = active;
        active = null;
        if (c == null) return;
        final observations = <_ExitObservation>[];
        try {
          for (final session in root
              .listSync()
              .whereType<Directory>()
              .where((d) => p.basename(d.path).startsWith('session-'))) {
            if (!File(p.join(session.path, 'settled')).existsSync()) {
              observations.add(await _ExitObservation.capture(session));
            }
          }
        } finally {
          // Diagnostic failure must still close our original client object.
          expect(await c.rpc.close(), 0);
        }
        for (final observation in observations) {
          await observation.report();
        }
        expect(c.rpc.forcedClose, isFalse);
        expect(c.rpc.protocolClean, isTrue);
        final sessions = root
            .listSync()
            .whereType<Directory>()
            .where((d) => p.basename(d.path).startsWith('session-'));
        for (final session in sessions) {
          await _waitFor(
              () => File(p.join(session.path, 'settled')).existsSync(),
              'compiled Bridge settlement after Codex EOF');
        }
      }

      try {
        var client = await connect();
        final competing = await Process.run(binary, [root.path],
            includeParentEnvironment: false,
            environment: const {'SHIROHA_PROCESS_ENV_PAD': ''});
        expect(competing.exitCode, 78);
        expect(competing.stdout, isEmpty);
        final targets = _data(await client.call('open_generation_context', {}));
        final target = (targets['items'] as List).first as Map;
        final context = _data(await client.call('open_generation_context',
            {'targetRef': target['targetRef']}))['contextRef'];
        final search = _data(await client.call(
            'search_questions', {'contextRef': context, 'query': 'needle'}));
        final question = (search['items'] as List).single as Map;
        expect(
            _data(await client.call('get_question_detail', {
              'contextRef': context,
              'questionRef': question['questionRef']
            }))['sourceKind'],
            'legacy');
        final files = _data(await client
            .call('open_generation_context', {'contextRef': context}));
        final file = _data(await client.call('open_generation_context', {
          'contextRef': context,
          'fileRefs': [(files['items'] as List).first['fileRef']]
        }))['contextRef'];
        final retrieval = _data(await client.call(
            'retrieve_file_content', {'contextRef': file, 'query': 'needle'}));
        final hit = (retrieval['items'] as List).single as Map;
        expect(
            _data(await client.call('get_file_passage', {
              'contextRef': file,
              'passageRef': hit['passageRef']
            }))['items'],
            isNotEmpty);
        final staged = client.call('propose_generated_questions', {
          'contextRef': context,
          'submission': jsonDecode(submission(key: 'compiled-original'))
        });
        await Future.any([
          _waitFor(() => app.approval.waitingForUser, 'App target approval'),
          staged.then((response) {
            final error = (response['result'] as Map?)?['structuredContent'];
            expect(app.approval.waitingForUser, isTrue,
                reason:
                    'STAGE completed before approval: ${error is Map ? error['error'] : 'client error'}');
          })
        ]);
        expect(await app.files.s.h.count('generated_question_proposals'), 0);
        await app.approvalView.confirm(app.approvalView.pending!);
        final stagedData = _data(await staged);
        expect(stagedData['publication'], 'STAGED');
        expect(
            _data(await client.call('get_question_proposal',
                {'submissionKey': 'compiled-original'}))['lifecycleStatus'],
            'pending_review');
        final local = await app.files.s.localFactory.openSession();
        try {
          var proposal = await local.read(stagedData['proposalId'] as String);
          final approval = local.confirmDisplayedTarget(proposal.target);
          proposal = await app.files.s.h.service.flush(
              GeneratedReviewFlush.fromJson({
                'proposalId': proposal.proposalId,
                'expectedReviewRevision': proposal.reviewRevision,
                'operations': [
                  for (final i in proposal.items)
                    {
                      'type': 'decide',
                      'itemId': i.itemId,
                      'decision': 'accepted'
                    }
                ]
              }),
              approval);
          await app.files.s.h.service.approve(
              ApproveGeneratedProposalCommand.fromJson({
                'proposalId': proposal.proposalId,
                'expectedReviewRevision': proposal.reviewRevision,
                'approvedItemIds': proposal.items.map((i) => i.itemId).toList()
              }),
              approval);
        } finally {
          local.close();
        }
        await disconnect();
        client = await connect();
        final revalidated = await client
            .call('open_generation_context', {'contextRef': context});
        expect(_data(revalidated)['items'], isA<List>());
        expect(
            _data(await client.call('get_question_proposal',
                {'submissionKey': 'compiled-original'}))['lifecycleStatus'],
            'committed');
        expect(await app.files.s.h.count('generated_question_proposals'), 1);
        expect(
            await app.files.s.h.count('generated_question_commit_receipts'), 1);
        final snapshots =
            BackupSnapshotRepository(databaseHelper: app.files.s.h.helper);
        final backup = BackupRestoreCoordinator(
            operations: BackupRestoreRuntime(
                databaseAuthority: SqliteBackupDatabaseAuthority(
                    beforeClose: app.integration.close,
                    databaseHelper: app.files.s.h.helper,
                    snapshotRepository: snapshots),
                snapshotRepository: snapshots,
                managedFileStorage:
                    ManagedFileStorageAdapter(managedRoot: app.files.managed),
                restoreRoot:
                    Directory(p.join(app.files.s.h.temp.path, 'restore')),
                managedFilesRoot: app.files.managed,
                diskSpaceProbe: _Disk()));
        final archive = p.join(app.files.s.h.temp.path, 'compiled.zip');
        await backup.exportTo(archive);
        await backup.prepareRestore(archive);
        await backup.commitPreparedRestore();
        expect(app.host.phase, WindowsTlsHostPhase.closed);
        expect(
            await (await app.files.s.h.helper.database)
                .query('external_client_profiles'),
            isEmpty);
        // Closed App cannot be reached by either the old or a restarted Bridge.
        await disconnect();
        expect(app.controls.isCurrent, isFalse);
        expect(app.approval.pendingCount, 0);
        client = await connect();
        final refused = await client.call('open_generation_context', {});
        expect(refused['result']['structuredContent']['error'], isNotNull);
      } finally {
        await disconnect();
      }
    },
        skip: codex == null ? 'Installed Codex not selected' : false,
        timeout: const Timeout(Duration(minutes: 3)));
  },
      skip: !Platform.isWindows
          ? 'Windows compiled process evidence only'
          : false);
}
