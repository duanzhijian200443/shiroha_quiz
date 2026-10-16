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
      } else {
        expect(source, isNot(contains('windows_tls_')), reason: path);
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
