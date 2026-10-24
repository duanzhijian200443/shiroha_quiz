import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('TLS13 isolated contexts, fixed Raw admission and crypt32 optional ABI',
      () {
    final config = File('lib/data/external/windows_tls_credentials.dart')
        .readAsStringSync();
    expect(config, contains('SecurityContext(withTrustedRoots: false)'));
    expect(config, contains('return _context ??='));
    expect(config.replaceAll(RegExp(r'\s'), ''),
        contains('minimumTlsProtocolVersion=TlsProtocolVersion.tls1_3'));
    final io = File('lib/data/external/windows_tls_io.dart').readAsStringSync();
    expect(io.replaceAll(RegExp(r'\s'), ''),
        contains('RawServerSocket.bind(InternetAddress.loopbackIPv4'));
    expect(io, contains('shared: false'));
    expect(io, contains('requireClientCertificate: true'));
    expect(io.indexOf('_socket = null;'),
        greaterThan(io.indexOf('await socket.close();')));
    expect(io, contains('_subscription = null;'));
    expect(io, contains('requestClientCertificate: true'));
    expect(io.replaceAll(RegExp(r'\s'), ''),
        contains('RawSecureSocket.connect(InternetAddress.loopbackIPv4'));
    final host =
        File('lib/data/external/windows_tls_host.dart').readAsStringSync();
    expect(host.indexOf('reserve(TlsResource.handshake)'),
        lessThan(host.indexOf('await raw.upgrade')));
    expect(host, contains('await projection.whenSettled'));
    for (final file in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final path = file.path.replaceAll('\\', '/');
      final source = file.readAsStringSync();
      if (path.startsWith('lib/data/external/windows_tls_')) {
        for (final token in [
          'defaultContext',
          'onBadCertificate',
          'keyLog:',
          'tls1_2',
          'withTrustedRoots: true'
        ]) {
          expect(source, isNot(contains(token)), reason: path);
        }
      } else if (path == 'lib/mcp/vnext_mcp_bridge_port.dart') {
        expect(source,
            contains("import '../data/external/windows_tls_transport.dart'"));
        expect(source, contains('!bridge.enableStageApprovalWait'));
        expect(source, contains('requestStageApproval('));
        final bridge = File('lib/data/external/windows_tls_bridge.dart')
            .readAsStringSync();
        expect(bridge, contains('this.enableStageApprovalWait = false'));
        expect(bridge, contains('if (!enableStageApprovalWait)'));
        expect(bridge, contains('FirstPartyStageLimits.bridgeResponse'));
        expect(bridge, contains('FirstPartyStageLimits.bridgeExchange'));
        final projection = File('lib/mcp/vnext_mcp_protocol_projection.dart')
            .readAsStringSync();
        expect(projection, contains("'schemaVersion': 3"));
        expect(
            projection,
            contains(
                'bridgeStageBlocked => contextKind == VnextMcpContextKind.stage'));
        expect(projection, contains("decoded['schemaVersion'] != 3"));
        for (final token in [
          '.connect(',
          'WindowsTlsBridge(',
          'ExternalTrustCore',
          '.openSession(',
          '.bindSession(',
          '.openRead(',
          '.openStage(',
          '.openReconciliation(',
          '.openProposalLifecycle(',
          '.approveTarget(',
          'IpcTrustedContextBinding',
          'ExternalPrincipal',
          'ExternalSession(',
          'ExternalExecutionContext',
          'AuthenticatedPeerEvidence(',
          'PairingProof(',
          'DatabaseHelper',
          'dart:io',
          'dart:ffi',
        ]) {
          expect(source, isNot(contains(token)), reason: path);
        }
      } else if (path == 'lib/composition/mcp_vnext_windows_acquisition.dart') {
        for (final token in [
          'dart:io',
          'dart:ffi',
          'Process.',
          'DatabaseHelper',
          'ExternalTrustCore(',
          'ExternalSession(',
          '.initialize(',
          '.recoverServer(',
          'jsonDecode',
          '.start(',
          '.bind(',
          '.connect(',
          'createSecurityContext('
        ]) {
          expect(source, isNot(contains(token)), reason: path);
        }
        expect(source,
            contains('listener: listener ?? const DartLoopbackTlsIo()'));
        expect(
            source,
            contains(
                'createIo: createIo ?? () => const DartLoopbackBridgeIo()'));
        expect(source, contains('native.peerCertificatePolicy.check'));
        expect(source, contains('WindowsAppPublicPairingHandoff('));
      } else if (path == 'lib/composition/mcp_vnext_windows_bootstrap.dart' ||
          path == 'lib/composition/mcp_vnext_windows_registration.dart') {
        for (final token in [
          'Platform.environment',
          'fromEnvironment',
          'jsonDecode',
          'Process.start',
          'Process.run',
          'Process.kill',
          'File(',
          'Directory(',
          'ExternalTrustCore(',
          'ExternalSession(',
          'ExternalPrincipal(',
          'PairingProof(',
          'AuthenticatedPeerEvidence(',
          'DatabaseHelper',
          '.initialize(',
          '.recoverServer(',
          '.enable(',
          '.approveTarget(',
          '.acquireBridgeObjects(',
          '.acquireAppObjects('
        ]) {
          expect(source, isNot(contains(token)), reason: path);
        }
        expect(source, contains('await requireSecurityAdmission();'));
      } else if (path == 'lib/composition/mcp_vnext_windows_startup.dart') {
        for (final token in [
          'dart:io',
          'dart:ffi',
          'Process.',
          'Platform.environment',
          'DatabaseHelper',
          'ExternalTrustCore(',
          'ExternalSession(',
          'ExternalPrincipal(',
          'PairingProof(',
          'AuthenticatedPeerEvidence(',
          '.initialize(',
          '.recoverServer(',
          '.acquireAppObjects(',
          '.acquireBridgeObjects(',
          'DartLoopbackTlsIo',
          'DartLoopbackBridgeIo',
          'jsonDecode',
          'print(',
          'debugPrint(',
          'DiscoveryDescriptorCodec',
          'PairingTranscriptCodec',
          'ExchangeMessageCodec',
          'ExternalBootstrapBytes',
          'readSubmission',
          'readChallenge',
          'readProof',
          'ExchangeFileRead',
          'ExchangePublication',
          'createCaptured',
          '.consume(',
          '.release(',
          'AppPairingRequest',
          'createChallenge',
          'initialDisplay',
          'completionDisplay'
        ]) {
          expect(source, isNot(contains(token)), reason: path);
        }
      } else if (path == 'lib/composition/mcp_vnext_windows_transport.dart' ||
          path == 'lib/composition/mcp_vnext_windows_bridge.dart') {
        for (final token in [
          'ExternalTrustCore',
          'ExternalSession',
          'ExternalPrincipal',
          'DatabaseHelper',
          'dart:io',
          'dart:ffi',
          '.approveTarget(',
          '.openSession(',
          'DartLoopbackTlsIo',
          'DartLoopbackBridgeIo',
          'P26TlsStartup',
          'RawServerSocket'
        ]) {
          expect(source, isNot(contains(token)), reason: path);
        }
      } else {
        expect(source, isNot(contains('windows_tls_')), reason: path);
      }
      if (path != 'lib/mcp/vnext_mcp_bridge_port.dart' &&
          path != 'lib/composition/mcp_vnext_windows_bridge.dart') {
        expect(source, isNot(contains('vnext_mcp_bridge_port')), reason: path);
        expect(source, isNot(contains('VnextMcpBridgePort')), reason: path);
      }
      if (path != 'lib/composition/mcp_vnext_windows_startup.dart' &&
          path != 'lib/composition/mcp_vnext_windows_acquisition.dart' &&
          path != 'lib/composition/mcp_vnext_windows_bootstrap.dart' &&
          path != 'lib/composition/mcp_vnext_windows_registration.dart') {
        expect(
            RegExp(r'(?:import|export).*mcp_vnext_windows_(?:transport|bridge|startup|acquisition)')
                .hasMatch(source),
            isFalse,
            reason: path);
      }
      if (path != 'lib/data/external/windows_bridge_process.dart' &&
          path != 'lib/composition/mcp_vnext_windows_startup.dart' &&
          path != 'lib/composition/mcp_vnext_windows_acquisition.dart' &&
          path != 'lib/composition/mcp_vnext_windows_bootstrap.dart' &&
          path != 'lib/composition/mcp_vnext_windows_registration.dart') {
        expect(
            RegExp(r'(?:import|export).*windows_bridge_process')
                .hasMatch(source),
            isFalse,
            reason: path);
      }
    }
    final policy = File('windows/external_native/peer_policy_windows.cpp')
        .readAsStringSync();
    for (final token in [
      'CryptDecodeObjectEx',
      'CertCreateCertificateContext',
      'CertVerifyTimeValidity',
      'CertFreeCertificateContext'
    ]) {
      expect(policy, contains(token));
    }
  });
  test(
      'fixed child retains original process and streams without PID operations',
      () {
    final source = File('lib/data/external/windows_bridge_process.dart')
        .readAsStringSync();
    for (final token in [
      'killPid',
      '.kill(',
      '.pid',
      'Platform.environment',
      'Process.run',
      'runInShell: true',
      'includeParentEnvironment: true',
      'Timer(',
      'dart:ffi',
      'OpenProcess'
    ]) {
      expect(source, isNot(contains(token)));
    }
    for (final token in [
      'WindowsExternalReleaseCandidate.inspect(',
      'Platform.resolvedExecutable',
      'Process.start(executable, const []',
      "environment: const {'SHIROHA_PROCESS_ENV_PAD': ''}",
      '_process.stdin.close()',
      '_process.exitCode',
      '_process.stdout.drain',
      '_process.stderr.drain'
    ]) {
      expect(source, contains(token));
    }
  });
  test(
      'all new suites registered once; static and Native import gates remain hard failing',
      () {
    final ci =
        File('.github/workflows/pr-contract-checks.yml').readAsStringSync();
    for (final name in [
      'windows_tls_transport',
      'windows_tls_source_guard',
      'windows_peer_certificate_policy'
    ]) {
      expect("'test/data/external/${name}_test.dart'".allMatches(ci).length, 1);
    }
    expect(File('tool/external/check_bootstrap_source.ps1').readAsStringSync(),
        contains('check_tls_source.ps1'));
    final cmake =
        File('windows/external_native/CMakeLists.txt').readAsStringSync();
    expect(cmake, contains('add_test(NAME shiroha_peer_policy_offline'));
    final check =
        File('windows/external_native/check_offline.ps1').readAsStringSync();
    expect(check, contains('shiroha_native_peer_certificate_policy'));
    expect(check, contains('shiroha_peer_policy_offline_test'));
  });
}
