import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
      'P24 keeps fixed native identity, nonblocking quota exclusion and no fallback',
      () {
    final core =
        File('windows/external_native/exchange_files.cpp').readAsStringSync();
    final win = File('windows/external_native/protected_windows.cpp')
        .readAsStringSync();
    final header = File('windows/external_native/shiroha_external_native.h')
        .readAsStringSync();
    expect(header, contains('SHIROHA_NATIVE_ABI_VERSION 3u'));
    expect(core, contains('L"exchange", true, false'));
    expect(core, contains('same(current, slot->identity)'));
    expect(core, contains('same(held, slot->identity)'));
    expect(core, contains('slot->token = 0;'));
    expect(core.indexOf('ops_.exchange_lock'),
        lessThan(core.indexOf('ops_.exchange_count')));
    expect(core, contains('entries > 32 || (create && entries == 32)'));
    expect(win, contains('WaitForSingleObject(mutex.value, 0)'));
    expect(win, contains('WAIT_ABANDONED'));
    expect(win, contains('SE_KERNEL_OBJECT'));
    expect(win, contains('mode == 0 ? FILE_CREATE : FILE_OPEN'));
    expect(win, contains('FileDispositionInfo'));
    for (final bad in [
      'DeleteFile',
      'MoveFileEx',
      'FILE_DELETE_ON_CLOSE',
      'FILE_OVERWRITE'
    ]) {
      expect(core, isNot(contains(bad)));
      expect(win, isNot(contains(bad)));
    }
    final script = File('windows/external_native/check_exchange_offline.ps1')
        .readAsStringSync();
    expect(
        script.indexOf(
            'Exchange Fake executable includes real security operations'),
        lessThan(script.indexOf('& '
            r'$ctest --test-dir')));
    expect(script, contains('actual.Count -ne 26'));
  });
  test(
      'one P22 parsing authority; no startup, state machine, file-path or polling access',
      () {
    final adapter = File('lib/data/external/windows_exchange_file_store.dart')
        .readAsStringSync();
    expect(adapter, contains('ExchangeMessageCodec.encode'));
    expect(adapter, contains('ExchangeMessageCodec.decode'));
    for (final token in [
      'dart:io',
      'dart:ffi',
      'PairingProof(',
      'AuthenticatedPeerEvidence(',
      'ExternalCredentialBoundary',
      'Timer(',
      'watch(',
      'listSync(',
      'ServerSocket'
    ]) {
      expect(adapter, isNot(contains(token)));
    }
    for (final entity
        in Directory('lib').listSync(recursive: true).whereType<File>()) {
      // P27 is an explicitly inactive composition-side consumer. Its own gate
      // rejects every production consumer and keeps P24 itself authority-free.
      if (p.equals(
              entity.absolute.path,
              p.absolute('lib', 'composition',
                  'mcp_vnext_development_pairing.dart')) ||
          p.equals(entity.absolute.path,
              p.absolute('lib', 'data', 'external', 'windows_pairing.dart')) ||
          p.equals(
              entity.absolute.path,
              p.absolute(
                  'lib', 'composition', 'mcp_vnext_windows_startup.dart')) ||
          p.equals(
              entity.absolute.path,
              p.absolute('lib', 'composition',
                  'mcp_vnext_windows_acquisition.dart'))) {
        continue;
      }
      if (p.extension(entity.path) != '.dart' ||
          p.equals(
              entity.absolute.path,
              p.absolute('lib', 'data', 'external',
                  'windows_exchange_file_store.dart'))) {
        continue;
      }
      expect(entity.readAsStringSync(),
          isNot(contains('WindowsExchangeFileStore')),
          reason: entity.path);
    }
  });
  test(
      'E0 same-handle content recheck, bounded pins and complete optional ABI lifecycle',
      () {
    final core =
        File('windows/external_native/exchange_files.cpp').readAsStringSync();
    final win = File('windows/external_native/protected_windows.cpp')
        .readAsStringSync();
    final policy = File('windows/external_native/exchange_open_policy.h')
        .readAsStringSync();
    final objects =
        File('windows/external_native/protected_objects.h').readAsStringSync();
    final ffi = File('lib/data/external/native/external_native_bindings.dart')
        .readAsStringSync();
    expect(core, contains('bytes != slot->bytes'));
    expect(core, contains('ops_.exchange_read(file, cap(slot->kind), bytes)'));
    expect(core, contains('ops_.exchange_delete(file)'));
    expect(objects, contains('std::array<ExchangeRead, 32>'));
    expect(core, contains('SecureZeroMemory(slot->nonce.data()'));
    expect(policy, contains('mode != 3 ? FILE_READ_DATA : 0'));
    expect(policy, contains('mode == 3 || mode == 4 ? DELETE : 0'));
    expect(
        policy,
        contains(
            'mode == 2 ? FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE : FILE_SHARE_READ'));
    expect(win, contains('exchange_access(mode), exchange_share(mode)'));
    expect(win, contains('actual.substr(actual.find_last_of'));
    expect(win, contains('BCRYPT_USE_SYSTEM_PREFERRED_RNG'));
    expect(ffi,
        contains('[_exchangeReadBegin, _exchangeConsume, _exchangeRelease]'));
    final workflow =
        File('.github/workflows/pr-contract-checks.yml').readAsStringSync();
    final standing =
        File('tool/ci/contract_test_suites.psd1').readAsStringSync();
    expect(
        "'test/data/external/windows_exchange_consumption_test.dart'"
            .allMatches(standing)
            .length,
        1);
    expect(
        workflow, contains('run: ./windows/external_native/check_offline.ps1'));
    final script =
        File('windows/external_native/check_offline.ps1').readAsStringSync();
    for (final symbol in ['read_begin', 'consume', 'release']) {
      expect(ffi, contains('shiroha_native_exchange_$symbol'));
      expect(script, contains('shiroha_native_exchange_$symbol'));
    }
    for (final entity
        in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (p.extension(entity.path) != '.dart' ||
          p.isWithin(p.absolute('lib/data/external'), entity.absolute.path)) {
        continue;
      }
      for (final token in [
        'ExchangeFileRead',
        'beginExchangeRead',
        'exchangeConsume',
        'readSubmissionForConsumption',
        'readChallengeForConsumption',
        'readProofForConsumption'
      ]) {
        expect(entity.readAsStringSync(), isNot(contains(token)),
            reason: entity.path);
      }
    }
  });
}
