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
    expect(script, contains('actual.Count -ne 23'));
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
}
