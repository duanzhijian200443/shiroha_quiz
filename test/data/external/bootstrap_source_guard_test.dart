import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const names = [
    'external_bootstrap_bytes.dart',
    'pairing_transcript_codec.dart',
    'exchange_message_codec.dart',
    'discovery_descriptor_codec.dart'
  ];
  test('P22 parsing has no native, file, network or P15 authority dependency',
      () {
    for (final name in names) {
      final code = File('lib/data/external/$name').readAsStringSync();
      for (final forbidden in [
        'dart:io',
        'dart:ffi',
        'native/',
        'WindowsExternalCrypto',
        'Random.secure',
        'BCrypt',
        'defaultContext',
        'onBadCertificate',
        'PairingProof(',
        'AuthenticatedPeerEvidence(',
        'ExternalCredentialBoundary',
        'LocalHostDispatchCore',
        'ServerSocket',
        'SecurityContext',
        'engine.'
      ]) {
        expect(code, isNot(contains(forbidden)), reason: name);
      }
    }
  });
  test('all P22 suites stand in CI once; source gate precedes execution', () {
    final workflow =
        File('.github/workflows/pr-contract-checks.yml').readAsStringSync();
    final standing =
        File('tool/ci/contract_test_suites.psd1').readAsStringSync();
    for (final name in [
      'pairing_transcript_codec',
      'exchange_message_codec',
      'discovery_descriptor_codec',
      'bootstrap_source_guard'
    ]) {
      expect(
          "'test/data/external/${name}_test.dart'".allMatches(standing).length,
          1);
    }
    final gate = workflow.indexOf('./tool/external/check_bootstrap_source.ps1');
    final tests =
        workflow.indexOf('& flutter test --concurrency=1 --file-reporter');
    expect(gate, greaterThan(0));
    expect(tests, greaterThan(gate));
  });
}
