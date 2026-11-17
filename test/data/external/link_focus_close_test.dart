import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/data/external/link/link_adapter_process.dart';
import 'package:shiroha_quiz/data/external/link/link_installation.dart';
import 'package:shiroha_quiz/data/external/link/link_values.dart';
import 'package:shiroha_quiz/data/external/link/link_verification_log.dart';
import '../../mcp/fixtures/codex_app_server_support.dart'
    show flutterDartExecutable;

void main() {
  for (final mode in ['closing', 'wrong-closing', 'duplicate-closing']) {
    test('original business child $mode requests EOF before exiting', () async {
      final root = await Directory.systemTemp.createTemp('link-close-');
      final signal = File(p.join(root.path, 'withdraw'));
      final observations = <LinkVerificationObservation>[];
      late Process process;
      final child = await LinkAdapterProcess.start(
          LinkInstallation(
              stateDirectory: root.path,
              slotDirectory: root.path,
              slotRef: 'phone',
              connectorInstanceId: 'connector',
              operationId: 'operation',
              adapterExecutable: p.join(root.path, 'adapter.exe')),
          runId: 'run',
          resourceId: 'resource',
          proof: false,
          acquired: (_) async {},
          verificationObserver: observations.add, startProcess: (_, __,
              {required runInShell, required workingDirectory}) async {
        final dart = flutterDartExecutable();
        final vm = File(p.join(
            p.dirname(dart), Platform.isWindows ? 'dartvm.exe' : 'dartvm'));
        return process = await Process.start(vm.existsSync() ? vm.path : dart, [
          '--disable-dart-dev',
          '--packages=${p.absolute('.dart_tool/package_config.json')}',
          p.absolute('test/data/external/fixtures/link_business_child.dart'),
          'run',
          'resource',
          signal.path,
          mode
        ]);
      });
      try {
        var exited = false;
        unawaited(process.exitCode.then((_) => exited = true));
        final reply = await child.call('open_context', {'scope': 'authorized'},
            cancelled: const Stream.empty());
        expect(reply['data'], {'contextRef': 'synthetic-read'});
        await signal.create();
        await child.disconnected.timeout(const Duration(seconds: 3));
        expect(exited, isFalse);
        if (mode == 'closing') {
          await child.close().timeout(const Duration(seconds: 3));
          expect(observations, hasLength(1));
        } else {
          await expectLater(
              child.close().timeout(const Duration(seconds: 3)),
              throwsA(isA<LinkException>()
                  .having((e) => e.code, 'code', 'owner_unsettled')));
          expect(observations, isEmpty);
        }
      } finally {
        await child.close().catchError((Object _) {});
        await process.exitCode;
        await root.delete(recursive: true);
      }
    });
  }
}
