import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/data/external/native/windows_external_native.dart';
import 'package:shiroha_quiz/data/external/windows_release_candidate.dart';

import 'external_native_test_support.dart';

Uint8List pe() {
  final bytes = Uint8List(512);
  final data = ByteData.sublistView(bytes);
  bytes[0] = 0x4d;
  bytes[1] = 0x5a;
  data.setUint32(0x3c, 64, Endian.little);
  data.setUint32(64, 0x4550, Endian.little);
  data.setUint16(68, 0x8664, Endian.little);
  data.setUint16(84, 240, Endian.little);
  data.setUint16(88, 0x20b, Endian.little);
  return bytes;
}

void main() {
  for (final role in ExternalReleaseRole.values) {
    test('C3 $role exact build inventory, no execution or activation', () {
      final names = role == ExternalReleaseRole.app
          ? WindowsExternalReleaseCandidate.appFiles
          : WindowsExternalReleaseCandidate.bridgeFiles;
      final files = {
        for (final name in names)
          name: ['.dll', '.exe'].contains(p.posix.extension(name))
              ? pe()
              : Uint8List.fromList([1])
      };
      WindowsExternalReleaseCandidate.inspect(role: role, files: files);
      files.remove(WindowsExternalReleaseCandidate.nativeLibrary);
      expect(
          () =>
              WindowsExternalReleaseCandidate.inspect(role: role, files: files),
          throwsFormatException);
      files[WindowsExternalReleaseCandidate.nativeLibrary] = pe();
      files['unowned-old-runtime.tmp'] = Uint8List(1);
      expect(
          () =>
              WindowsExternalReleaseCandidate.inspect(role: role, files: files),
          throwsFormatException);
      expect(files.containsKey('unowned-old-runtime.tmp'), isTrue); // No sweep.
    });
  }

  for (final mode in [
    'truncated',
    'dos',
    'offset',
    'signature',
    'x86',
    'arm64',
    'optional'
  ]) {
    test('C3 malformed/wrong architecture PE $mode rejected statically', () {
      var bytes = pe();
      final data = ByteData.sublistView(bytes);
      switch (mode) {
        case 'truncated':
          bytes = Uint8List(63);
        case 'dos':
          bytes[0] = 0;
        case 'offset':
          data.setUint32(0x3c, 0xffffffff, Endian.little);
        case 'signature':
          bytes[64] = 0;
        case 'x86':
          data.setUint16(68, 0x14c, Endian.little);
        case 'arm64':
          data.setUint16(68, 0xaa64, Endian.little);
        case 'optional':
          data.setUint16(88, 0x10b, Endian.little);
      }
      expect(() => WindowsExternalReleaseCandidate.inspectX64Pe(bytes),
          throwsFormatException);
    });
  }

  test(
      'C3 declared plugin and asset paths must match complete canonical inventory',
      () {
    final files = {
      for (final name in WindowsExternalReleaseCandidate.appFiles)
        name: ['.dll', '.exe'].contains(p.posix.extension(name))
            ? pe()
            : Uint8List.fromList([1])
    };
    expect(
        () => WindowsExternalReleaseCandidate.inspect(
            role: ExternalReleaseRole.app,
            files: files,
            declaredPluginLibraries: {'reviewed_plugin.dll'}),
        throwsFormatException);
    files['reviewed_plugin.dll'] = pe();
    WindowsExternalReleaseCandidate.inspect(
        role: ExternalReleaseRole.app,
        files: files,
        declaredPluginLibraries: {'reviewed_plugin.dll'});
    files['data/flutter_assets/a/../unowned'] = Uint8List(1);
    expect(
        () => WindowsExternalReleaseCandidate.inspect(
            role: ExternalReleaseRole.app,
            files: files,
            declaredPluginLibraries: {'reviewed_plugin.dll'}),
        throwsFormatException);
  });

  for (final path in [
    r'C:\Program Files\Shiroha\shiroha_bridge.exe',
    r'C:\离线候选\测 试\shiroha_bridge.exe'
  ]) {
    test('C3 Native resolved executable path supports spaces/Unicode: $path',
        () {
      final calls = FakeExternalNativeCalls();
      final attempted = <String>[];
      WindowsExternalNative.openForTesting(
          windows: true,
          executable: path,
          exists: (dll) {
            attempted.add(dll);
            return true;
          },
          load: (dll) {
            expect(
                dll,
                p.windows.join(p.windows.dirname(path),
                    WindowsExternalNative.libraryName));
            return calls;
          });
      expect(attempted, [
        p.windows
            .join(p.windows.dirname(path), WindowsExternalNative.libraryName)
      ]);
      expect(calls.owners, isEmpty);
      expect(calls.operationCount, 0); // No DPAPI/NTFS/security call.
    });
  }

  for (final mode in ['missing', 'wrongDll', 'abi']) {
    test('C3 $mode Native never falls back to PATH/CWD or acquires Owner', () {
      final calls = FakeExternalNativeCalls();
      if (mode == 'abi') calls.version = 4;
      var probes = 0, loads = 0;
      expect(
          () => WindowsExternalNative.openForTesting(
              windows: true,
              executable: r'C:\Synthetic Unicode 候选\shiroha_bridge.exe',
              exists: (_) {
                probes++;
                return mode != 'missing';
              },
              load: (_) {
                loads++;
                if (mode == 'wrongDll') throw StateError('fixed invalid image');
                return calls;
              }),
          throwsA(isA<ExternalNativeException>()));
      expect(probes, 1);
      expect(loads, mode == 'missing' ? 0 : 1);
      expect(calls.owners, isEmpty);
    });
  }

  test('C3 arguments cannot configure host, env, credentials or activation',
      () {
    expect(WindowsExternalReleaseCandidate.acceptsArguments([]), isTrue);
    for (final argument in [
      '--enable',
      '--host=0.0.0.0',
      '--dll=other.dll',
      '--root=..',
      '--env=PATH'
    ]) {
      expect(WindowsExternalReleaseCandidate.acceptsArguments([argument]),
          isFalse);
    }
    final entry =
        File('tool/external/bridge_candidate.dart').readAsStringSync();
    expect(entry, contains('exitCode = 78;'));
    for (final forbidden in [
      '.connect(',
      '.acquireAppObjects(',
      '.acquireBridgeObjects(',
      'Platform.environment',
      'Directory.current',
      'Process.start',
      'WindowsExternalNative.open('
    ]) {
      expect(entry, isNot(contains(forbidden)));
    }
  });

  test(
      'C3 full standalone Bridge import closure excludes App DB/writers/Flutter',
      () {
    final pending = [p.absolute('tool/external/bridge_candidate.dart')];
    final seen = <String>{};
    final root = p.absolute('.');
    final imports = RegExp("(?:import|export|part)\\s+'([^']+)'");
    while (pending.isNotEmpty) {
      final path = p.normalize(pending.removeLast());
      if (!seen.add(path)) continue;
      expect(p.isWithin(root, path), isTrue);
      final relative = p.posix.joinAll(p.split(p.relative(path, from: root)));
      for (final forbidden in [
        'lib/data/repositories/',
        'lib/helpers/',
        'lib/main.dart',
        'lib/services/backup_service.dart',
        'lib/services/provider_key_store.dart'
      ]) {
        expect(relative.startsWith(forbidden), isFalse, reason: relative);
      }
      final source = File(path).readAsStringSync();
      for (final match in imports.allMatches(source)) {
        final uri = match[1]!;
        if (uri.startsWith('dart:')) continue;
        if (uri.startsWith('package:shiroha_quiz/')) {
          pending.add(p.join(
              root, 'lib', uri.substring('package:shiroha_quiz/'.length)));
        } else if (uri.startsWith('package:')) {
          expect([
            'package:path/path.dart',
            'package:meta/meta.dart'
          ], contains(uri), reason: relative);
        } else {
          pending.add(p.normalize(p.join(p.dirname(path), uri)));
        }
      }
    }
    expect(
        seen.length, greaterThan(20)); // Audit traversed the actual transport.
  });

  test('C4 current Native/FFI ABI and hard failing CI registrations stay exact',
      () {
    final bindings =
        File('lib/data/external/native/external_native_bindings.dart')
            .readAsStringSync();
    final symbols = RegExp("'(shiroha_native_[a-z_]+)'")
        .allMatches(bindings)
        .map((m) => m[1]!)
        .toSet();
    expect(symbols.length, 27);
    expect(WindowsExternalReleaseCandidate.nativeAbi,
        WindowsExternalNative.abiVersion);
    final native =
        File('windows/external_native/check_offline.ps1').readAsStringSync();
    expect(native, contains('FFI/DLL symbol mismatch'));
    expect(native, contains('/dependents'));
    final ci =
        File('.github/workflows/pr-contract-checks.yml').readAsStringSync();
    for (final name in ['windows_tls_lifecycle', 'windows_release_candidate']) {
      expect("'test/data/external/${name}_test.dart'".allMatches(ci).length, 1);
    }
    final cmake = File('windows/CMakeLists.txt').readAsStringSync();
    expect(cmake, contains('install(TARGETS shiroha_external_native'));
    expect(cmake, contains('CONFIGURATIONS Profile;Release'));
    expect(File('lib/main.dart').readAsStringSync(),
        isNot(contains('windows_tls_')));
  });
}
