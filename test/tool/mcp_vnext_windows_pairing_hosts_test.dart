import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../tool/mcp_vnext_windows_app_smoke.dart'
    show smokeOwner, smokePrefix;
import '../../tool/mcp_vnext_windows_pairing_host_support.dart';

void main() {
  test('pairing hosts accept only an explicit marked, owned temporary root',
      () async {
    expect(() => pairingHostRoot(''), throwsStateError);
    expect(() => pairingHostRoot('relative'), throwsStateError);
    final root = await Directory.systemTemp.createTemp(smokePrefix);
    addTearDown(() => root.delete(recursive: true));
    expect(() => pairingHostRoot(root.path), throwsStateError);
    await File(p.join(root.path, '.smoke-owner')).writeAsString('foreign');
    expect(() => pairingHostRoot(root.path), throwsStateError);
    await File(p.join(root.path, '.smoke-owner')).writeAsString(smokeOwner);
    expect(pairingHostRoot(root.path).path, root.resolveSymbolicLinksSync());
    final nested = await Directory(p.join(root.path, smokePrefix)).create();
    await File(p.join(nested.path, '.smoke-owner')).writeAsString(smokeOwner);
    expect(() => pairingHostRoot(nested.path), throwsStateError);
  });

  test('evidence is fresh-only, ordered and free of absolute paths', () async {
    final root = await Directory.systemTemp.createTemp(smokePrefix);
    addTearDown(() => root.delete(recursive: true));
    final file = File(p.join(root.path, 'host-events.jsonl'));
    final evidence = PairingHostEvidence(file)..record('host_ready');
    evidence.record('script_complete', {
      'submissionBytes': 32,
      'enabled': false,
      'private': <String>['drop me'],
    });
    expect(evidence.completed, isTrue);
    final lines = file.readAsLinesSync();
    expect(lines.length, 2);
    expect(lines.first, contains('"stage":"host_ready"'));
    expect(lines.last, contains('"submissionBytes":32'));
    expect(file.readAsStringSync(), isNot(contains('drop me')));
    expect(file.readAsStringSync(), isNot(contains(root.path)));
    expect(() => PairingHostEvidence(file), throwsStateError);
  });

  test('the public link publishes atomically and bounds its wait', () async {
    final root = await Directory.systemTemp.createTemp(smokePrefix);
    addTearDown(() => root.delete(recursive: true));
    final link = PairingHostLink(Directory(p.join(root.path, 'link')));
    await link.prepare();
    await link.publishText(PairingLinkFile.submissionId, 'a' * 32);
    expect(await link.waitText(PairingLinkFile.submissionId), 'a' * 32);
    expect(await link.readTextIfPresent('absent'), isNull);
    await expectLater(
        link.wait('absent', timeout: const Duration(milliseconds: 200)),
        throwsStateError);
    expect(Directory(link.root.path).listSync().length, 1);
  });

  test('both hosts are explicit test entrypoints without native acquisition',
      () {
    for (final path in [
      'tool/mcp_vnext_windows_bridge_ui_host.dart',
      'tool/mcp_vnext_windows_app_pairing_host.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, contains('pairingHostRoot('), reason: path);
      expect(source, isNot(contains('WindowsExternalNative')), reason: path);
      expect(source, isNot(contains('acquireAppObjects')), reason: path);
      expect(source, isNot(contains('acquireBridgeObjects')), reason: path);
      expect(source, isNot(contains('runShirohaQuiz')), reason: path);
    }
    final main = File('lib/main.dart').readAsStringSync();
    expect(main, isNot(contains('bridge_ui_host')));
    expect(main, isNot(contains('BridgeUiHost')));
    final controller =
        File('tool/run_mcp_vnext_windows_pairing_hosts.mjs').readAsStringSync();
    expect(controller, contains("'peer-abort'"));
    expect(controller, contains('app-host/shiroha_quiz.exe'));
    expect(controller, contains('bridge-host/shiroha_quiz.exe'));
    expect(controller, contains('MCP-VNEXT-WINDOWS-APP-FUNCTIONAL-SMOKE'));
  });
}
