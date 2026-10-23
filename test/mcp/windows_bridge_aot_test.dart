// Opt-in real Windows candidate checks. No protected Owner or TLS is acquired.
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/data/external/windows_bridge_process.dart';
import 'package:shiroha_quiz/data/external/windows_release_candidate.dart';
import 'package:shiroha_quiz/data/external/windows_tls_transport.dart';
import '../application/generated_question/generated_test_support.dart'
    show initializeGeneratedTests;
import 'fixtures/codex_app_server_support.dart';
import 'fixtures/windows_app_transport_fixture.dart';

// Actual formal package, with a test-selected disposable installation.
// Private adjacent-path discovery is separately tested by the AOT probe.
final class _AotIo implements WindowsBridgeProcessIo {
  _AotIo(this.directory);
  final String directory;
  _AotChild? child;
  @override
  Future<Map<String, Uint8List>> inspect() async => {
        for (final name in WindowsExternalReleaseCandidate.bridgeFiles)
          name: await File(p.join(directory, name)).readAsBytes()
      };
  @override
  Future<WindowsCreatedBridgeProcess> create() async => child = _AotChild(
      await Process.start(p.join(directory, 'shiroha_bridge.exe'), const [],
          includeParentEnvironment: false,
          environment: const {'SHIROHA_PROCESS_ENV_PAD': ''}));
}

final class _AotChild implements WindowsCreatedBridgeProcess {
  _AotChild(this.original) {
    settlement = Future.wait<int>([
      original.exitCode,
      original.stdout.drain<void>().then((_) => 0),
      original.stderr.drain<void>().then((_) => 0),
    ]).then((values) => values.first);
  }
  final Process original;
  @override
  late final Future<int> settlement;
  @override
  Future<int> get exitCode => original.exitCode;
  @override
  Future<void> closeInput() => original.stdin.close();
}

void main() {
  initializeGeneratedTests();
  final package = Platform.environment['SHIROHA_BRIDGE_PACKAGE'];
  final codex = Platform.environment['SHIROHA_CODEX_EXE'];
  group('formal Bridge AOT', () {
    late Directory sandbox;
    late String bridge, probe;
    setUpAll(() async {
      final root = await Directory(
              p.join(Directory.current.path, '.dart_tool', 'ar-r6b-aot-tests'))
          .create(recursive: true);
      sandbox = await root.createTemp('相邻 Bridge ');
      bridge = p.join(sandbox.path, 'shiroha_bridge.exe');
      for (final name in [
        'shiroha_bridge.exe',
        'shiroha_external_native.dll'
      ]) {
        await File(p.join(package!, name)).copy(p.join(sandbox.path, name));
      }
      probe = p.join(sandbox.path, 'custody_probe.exe');
      final build = await Process.run(flutterDartExecutable(), [
        'compile',
        'exe',
        'test/mcp/fixtures/windows_bridge_aot_probe.dart',
        '-o',
        probe
      ]);
      expect(build.exitCode, 0, reason: 'Compile adjacent test owner');
    });
    tearDownAll(() async => sandbox.delete(recursive: true));

    test('isolated App startup launches formal child and owns its shutdown',
        () async {
      final io = _AotIo(sandbox.path);
      final process = WindowsBridgeProcess(io: io);
      final app = WindowsAppTransportFixture()
        ..appProcessOverride = process
        ..useAcceptedLocalConnection = true;
      await app.open(stage: false, productBridge: true);
      addTearDown(app.close);
      expect(process.isCurrent, isTrue);
      expect((await app.call('open_generation_context'))['error'], isNull);
      await app.startup.close();
      expect(await io.child!.exitCode, 0);
      expect(await io.child!.settlement, 0);
      expect(app.host.phase, WindowsTlsHostPhase.closed);
      expect(app.pairing.native.owner.isClosed, isTrue);
      expect(process.isCurrent, isFalse);
    });

    test('fixed Native loader binds original DLL and ABI only', () async {
      final result = await Process.run(probe, ['loader'],
          includeParentEnvironment: false,
          environment: const {'SHIROHA_PROCESS_ENV_PAD': ''});
      expect(result.exitCode, 0);
      expect(result.stdout, 'abiLoaded\n');
      expect(result.stderr, isEmpty);
    });
    for (final mode in ['lifecycle', 'interrupted']) {
      test('private adjacent launcher/wrapper $mode settles', () async {
        final result = await Process.run(probe, [mode],
            includeParentEnvironment: false,
            environment: const {'SHIROHA_PROCESS_ENV_PAD': ''});
        expect(result.exitCode, 0);
        expect((result.stdout as String).trim(), 'settled');
        expect(result.stderr, isEmpty);
      });
    }
    test('missing adjacent DLL refuses loader and launch without fallback',
        () async {
      final missing = await sandbox.createTemp('missing-dll-');
      final isolatedProbe = p.join(missing.path, 'custody_probe.exe');
      await File(probe).copy(isolatedProbe);
      await File(bridge).copy(p.join(missing.path, 'shiroha_bridge.exe'));
      for (final mode in ['loader', 'lifecycle']) {
        final result = await Process.run(isolatedProbe, [mode],
            includeParentEnvironment: false,
            environment: const {'SHIROHA_PROCESS_ENV_PAD': ''});
        expect(result.exitCode, 1);
        expect(result.stdout, isEmpty);
        expect((result.stderr as String).trim(), 'probeFailed');
      }
      // The suite's single teardown owns every copied package, including this
      // negative case. Keep cleanup mandatory after all original process joins.
    });
    test('invalid activation arguments fail with 64 and no protocol output',
        () async {
      final result = await Process.run(bridge, ['--activate']);
      expect(result.exitCode, 64);
      expect(result.stdout, isEmpty);
      expect((result.stderr as String).trim(), 'invalidBridgeArguments');
    });
    test('actual AOT protocol discovery, refusal, EOF and restart', () async {
      for (var run = 0; run < 2; run++) {
        final rpc = await JsonLineProcess.start(bridge, [],
            cwd: sandbox.path, home: sandbox.path);
        try {
          final init = await rpc.request(
              'initialize',
              {
                'protocolVersion': '2025-11-25',
                'capabilities': {},
                'clientInfo': {'name': 'aot_probe', 'version': '1'}
              },
              mcp: true);
          expect(init['result']['serverInfo']['version'], '0.2.0');
          rpc.send({'jsonrpc': '2.0', 'method': 'notifications/initialized'});
          final tools = await rpc.request('tools/list', {}, mcp: true);
          expect(tools['result']['tools'], hasLength(7));
          for (final call in [
            {'name': 'open_generation_context', 'arguments': {}},
            {
              'name': 'get_question_proposal',
              'arguments': {'submissionKey': 'original-key'}
            }
          ]) {
            final result = await rpc.request('tools/call', call, mcp: true);
            expect(
                result['result']['structuredContent']['error'], 'unavailable');
          }
        } finally {
          expect(await rpc.close(), 0);
          expect(rpc.forcedClose, isFalse);
          expect(rpc.protocolClean, isTrue);
        }
      }
    });
    test('installed Codex discovers actual AOT and reconnects with refusal',
        () async {
      for (var run = 0; run < 2; run++) {
        final home = await sandbox.createTemp('codex-home-');
        final client = InstalledCodex(codex!, Directory.current.path, home);
        await client.configure(command: bridge, commandArguments: []);
        try {
          await client.start();
          final inventory = await client.inventory();
          expect(inventory['result']['data'].single['tools'], hasLength(7));
          final result = await client.call('open_generation_context', {});
          expect(result['result']['structuredContent']['error'], 'unavailable');
        } finally {
          expect(await client.rpc.close(), 0);
          expect(client.rpc.forcedClose, isFalse);
          expect(client.rpc.protocolClean, isTrue);
          await home.delete(recursive: true);
        }
      }
    }, skip: codex == null ? 'Installed Codex not selected' : false);
  },
      skip: !Platform.isWindows || package == null
          ? 'UNVERIFIED: Windows and explicit SHIROHA_BRIDGE_PACKAGE required'
          : false);
}
