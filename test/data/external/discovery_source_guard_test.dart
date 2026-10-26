import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fixed optional ABI and native role/identity/ordering remain explicit',
      () {
    final core =
        File('windows/external_native/discovery_files.cpp').readAsStringSync();
    final header = File('windows/external_native/shiroha_external_native.h')
        .readAsStringSync();
    final bindings =
        File('lib/data/external/native/external_native_bindings.dart')
            .readAsStringSync();
    for (final name in [
      'shiroha_native_discovery_publish',
      'shiroha_native_discovery_read'
    ]) {
      expect(header, contains(name));
      expect(bindings, contains("'$name'"));
      expect(bindings.indexOf("'$name'"),
          greaterThan(bindings.indexOf('late final _discovery')));
    }
    expect(core, contains('publish && lease->role != SHIROHA_NATIVE_APP'));
    expect(core, contains('L"discovery", true, false'));
    expect(core, contains('same(temp_identity, after)'));
    expect(core, contains('same(identity, after)'));
    expect(core,
        contains('lease->denied = true; return SHIROHA_NATIVE_COMMIT_UNKNOWN'));
    expect(core.indexOf('ops_.write_file'),
        lessThan(core.indexOf('ops_.flush_file')));
    expect(core.indexOf('ops_.flush_file'),
        lessThan(core.indexOf('ops_.discovery_replace')));
    for (final token in [
      'exchange_delete(',
      'DeleteFile',
      'MoveFileEx',
      'FILE_DELETE_ON_CLOSE'
    ]) {
      expect(core, isNot(contains(token)));
    }
  });
  test(
      'only inactive infrastructure consumes discovery, CI registers acceptance',
      () {
    // The dormant startup root publishes by design. The trusted Bootstrap root
    // is not exempt: it keeps the P26 scan with one exact Reader allowance.
    const owned = [
      'lib/data/external/windows_discovery.dart',
      'lib/data/external/windows_credential_initialization.dart',
      'lib/data/external/windows_tls_transport.dart',
      'lib/data/external/windows_tls_credentials.dart',
      'lib/data/external/windows_tls_bridge.dart',
      'lib/composition/mcp_vnext_windows_startup.dart'
    ];
    const trusted = 'lib/composition/mcp_vnext_windows_bootstrap.dart';
    const proof = 'lib/composition/mcp_vnext_development_pairing.dart';
    const proofForbidden = [
      'WindowsDiscoveryPublisher',
      'publishDiscovery',
      'readDiscovery',
      '.request(',
      '.requestStageApproval(',
      'store.write(',
      'store.initializeMissing(',
    ];
    void expectProofOnly(String code) {
      for (final token in proofForbidden) {
        expect(code, isNot(contains(token)), reason: proof);
      }
      expect(RegExp('WindowsDiscoveryReader').allMatches(code).length, 1,
          reason: proof);
      expect(code, contains('await connection.waitForProofClosure()'),
          reason: proof);
      expect(
          code,
          contains(
              'requirePublication: admitted.packet.requireCurrentPublication'),
          reason: proof);
    }

    void expectReaderOnly(String path, String code) {
      final body = code.replaceFirst(
          "import '../data/external/windows_discovery.dart';", '');
      expect(
          RegExp(r'windows_discovery|WindowsDiscoveryPublisher|publishDiscovery|readDiscovery')
              .hasMatch(body),
          isFalse,
          reason: path);
      expect(RegExp('WindowsDiscoveryReader').allMatches(body).length, 1,
          reason: path);
      expect(
          RegExp(r'WindowsDiscoveryReader\([\s\S]*?\)\s*\.\s*readAndAdvanceExistingPin\(')
              .hasMatch(body),
          isTrue,
          reason: path);
    }

    for (final file in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final path = file.path.replaceAll('\\', '/');
      if (owned.contains(path)) continue;
      final code = file.readAsStringSync();
      if (path == trusted) {
        expectReaderOnly(path, code);
        continue;
      }
      if (path == proof) {
        expectProofOnly(code);
        continue;
      }
      expect(code, isNot(contains('WindowsDiscoveryPublisher')), reason: path);
      expect(code, isNot(contains('WindowsDiscoveryReader')), reason: path);
    }
    // Negative control: publication or a second/non-advancing Reader in the
    // privileged Bootstrap root must fail the same in-memory assertions.
    final source = File(trusted).readAsStringSync();
    for (final mutation in [
      '$source\nWindowsDiscoveryPublisher(owner: owner, credentials: credentials);',
      '$source\nfinal reader = WindowsDiscoveryReader(owner);',
      source.replaceFirst('readAndAdvanceExistingPin(', 'read('),
    ]) {
      expect(() => expectReaderOnly(trusted, mutation), throwsA(anything));
    }
    // Exact mirror of the seven prohibited capabilities and two required
    // proof/publication checks in check_discovery_source.ps1 (nine mutations).
    final proofSource = File(proof).readAsStringSync();
    for (final mutation in [
      for (final token in proofForbidden) '$proofSource\n$token',
      proofSource.replaceFirst(
          'requirePublication: admitted.packet.requireCurrentPublication', ''),
      proofSource.replaceFirst('await connection.waitForProofClosure()', ''),
    ]) {
      expect(mutation, isNot(proofSource));
      expect(() => expectProofOnly(mutation), throwsA(anything));
    }
    final workflow =
        File('.github/workflows/pr-contract-checks.yml').readAsStringSync();
    for (final name in ['windows_discovery', 'discovery_source_guard']) {
      expect(
          "'test/data/external/${name}_test.dart'".allMatches(workflow).length,
          1);
    }
    final cmake =
        File('windows/external_native/CMakeLists.txt').readAsStringSync();
    expect(cmake, contains('add_test(NAME shiroha_discovery_offline'));
    final scan =
        File('windows/external_native/check_offline.ps1').readAsStringSync();
    expect(scan, contains("@('shiroha_discovery_offline_test'"));
    expect(
        scan.indexOf(
            'Offline executable includes a real security/file operation'),
        lessThan(scan.indexOf(r'& $ctest --test-dir')));
    expect(File('tool/external/check_bootstrap_source.ps1').readAsStringSync(),
        contains('check_discovery_source.ps1'));
  });
}
