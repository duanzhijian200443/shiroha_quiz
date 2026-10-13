import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/external/native/windows_external_native.dart';

import 'external_native_test_support.dart';

Matcher fails(ExternalNativeFailure failure) =>
    throwsA(isA<ExternalNativeException>()
        .having((e) => e.failure, 'failure', failure));

void main() {
  late FakeExternalNativeCalls calls;
  late WindowsExternalNative adapter;

  setUp(() {
    calls = FakeExternalNativeCalls();
    adapter = WindowsExternalNative.openForTesting(
      windows: true,
      executable: r'C:\synthetic application\shiroha.exe',
      exists: (_) => true,
      load: (_) => calls,
    );
  });
  tearDown(() => expect(calls.allocations, isEmpty));

  test('non-Windows refuses before filesystem, loader or ABI access', () {
    expect(
        () => WindowsExternalNative.openForTesting(
            windows: false,
            executable: '/synthetic/app',
            exists: (_) => throw StateError('must not read'),
            load: (_) => throw StateError('must not load')),
        fails(ExternalNativeFailure.unsupportedPlatform));
  });

  test(
      'loads only the absolute process directory, including Unicode and spaces',
      () {
    final paths = <String>[];
    WindowsExternalNative.openForTesting(
      windows: true,
      executable: r'C:\合成 😀 目录\bridge.exe',
      exists: (path) {
        paths.add(path);
        return true;
      },
      load: (path) {
        paths.add(path);
        return calls;
      },
    );
    expect(paths, [
      r'C:\合成 😀 目录\shiroha_external_native.dll',
      r'C:\合成 😀 目录\shiroha_external_native.dll'
    ]);
    expect(calls.operationCount, 0);
    expect(calls.allocationCount, 0);
  });

  test('relative executable and missing DLL reject without alternate search',
      () {
    var loads = 0;
    for (final executable in [r'relative\app.exe', r'C:\synthetic\app.exe']) {
      expect(
          () => WindowsExternalNative.openForTesting(
              windows: true,
              executable: executable,
              exists: (_) => false,
              load: (_) {
                loads++;
                return calls;
              }),
          fails(ExternalNativeFailure.libraryUnavailable));
    }
    expect(loads, 0);
  });

  test('loader/symbol failure is redacted; no retry or fallback', () {
    expect(
        () => WindowsExternalNative.openForTesting(
            windows: true,
            executable: r'C:\synthetic\app.exe',
            exists: (_) => true,
            load: (_) => throw StateError('synthetic private loader path')),
        fails(ExternalNativeFailure.libraryUnavailable));
    expect(
        const ExternalNativeException(ExternalNativeFailure.libraryUnavailable)
            .toString(),
        'ExternalNativeException(libraryUnavailable)');
  });

  test('incompatible version rejects before native allocation/operation', () {
    calls.version = 2;
    expect(() => adapter.protect(Uint8List.fromList([1])),
        fails(ExternalNativeFailure.abiMismatch));
    expect(() => adapter.resolveLocalAppData(),
        fails(ExternalNativeFailure.abiMismatch));
    expect(calls.allocationCount, 0);
    expect(calls.operationCount, 0);
    expect(
        () => WindowsExternalNative.openForTesting(
            windows: true,
            executable: r'C:\synthetic\app.exe',
            exists: (_) => true,
            load: (_) => calls),
        fails(ExternalNativeFailure.abiMismatch));
  });

  test('empty and oversize data reject without touching native memory', () {
    for (final input in [Uint8List(0), Uint8List(65537)]) {
      expect(() => adapter.protect(input),
          fails(ExternalNativeFailure.invalidInput));
      expect(() => adapter.unprotect(input),
          fails(ExternalNativeFailure.invalidInput));
    }
    expect(calls.allocationCount, 0);
    expect(calls.operationCount, 0);
  });

  test('maximum bounded input copies and releases exactly once before return',
      () {
    final input = Uint8List(WindowsExternalNative.maxBytes)..[0] = 1;
    final protected = adapter.protect(input);
    expect(protected, [9, 8, 7]);
    expect(calls.capturedInput, input);
    expect(input[0], 1);
    expect(calls.freed.length, 3);
    expect(calls.freed.toSet().length, 3);
    expect(calls.allocations, isEmpty);
    expect(calls.events[calls.events.length - 4], 'version');
    calls.result[0] = 0;
    expect(protected, [9, 8, 7]); // No native view or result alias escaped.
  });

  for (final entry in {
    1: ExternalNativeFailure.invalidInput,
    2: ExternalNativeFailure.abiMismatch,
    3: ExternalNativeFailure.resourceLimit,
    4: ExternalNativeFailure.temporarilyUnavailable,
    5: ExternalNativeFailure.dataCorrupt,
    99: ExternalNativeFailure.invalidNativeResult,
  }.entries) {
    test(
        'native status ${entry.key} denies both operations and releases results',
        () {
      calls.status = entry.key;
      expect(
          () => adapter.protect(Uint8List.fromList([1])), fails(entry.value));
      expect(
          () => adapter.unprotect(Uint8List.fromList([1])), fails(entry.value));
      expect(calls.operationCount, 2);
      expect(calls.freed.length, 6);
    });
  }

  for (final step in [1, 2, 3]) {
    test('allocation failure $step frees every earlier allocation', () {
      calls.failAllocation = step;
      expect(() => adapter.protect(Uint8List.fromList([1])),
          fails(ExternalNativeFailure.resourceLimit));
      expect(calls.freed.length, step - 1);
      expect(calls.operationCount, 0);
    });
  }

  test('exception after writing partial bytes returns no result and frees all',
      () {
    calls.throwOperation = true;
    expect(() => adapter.unprotect(Uint8List.fromList([1])),
        fails(ExternalNativeFailure.temporarilyUnavailable));
    expect(calls.freed.length, 3);
    expect(calls.operationCount, 1); // No reconstruction/retry of trust.
  });

  for (final size in [0, 65537]) {
    test(
        'successful native status with invalid output length $size is rejected',
        () {
      calls.outputLength = size;
      expect(() => adapter.unprotect(Uint8List.fromList([1])),
          fails(ExternalNativeFailure.invalidNativeResult));
      expect(calls.freed.length, 3);
    });
  }

  test('known-folder UTF-16 preserves Unicode and carries no validation claim',
      () {
    const path = r'C:\synthetic user\合成 😀';
    final data = ByteData(path.length * 2);
    for (var i = 0; i < path.length; i++) {
      data.setUint16(i * 2, path.codeUnitAt(i), Endian.little);
    }
    calls.result = data.buffer.asUint8List();
    final result = adapter.resolveLocalAppData();
    expect(result.value, path);
    expect(result.toString(), 'ExternalLocalAppDataPath(REDACTED)');
    expect(calls.freed.length, 2);
  });

  for (final invalid in [
    [65], // Odd byte length.
    [0, 0], // NUL.
    [0, 0xd8], // Unpaired high surrogate.
    [0, 0xdc], // Unpaired low surrogate.
    [65, 0], // Relative path.
  ]) {
    test('malformed folder output $invalid rejects after release', () {
      calls.result = Uint8List.fromList(invalid);
      expect(() => adapter.resolveLocalAppData(),
          fails(ExternalNativeFailure.invalidNativeResult));
      expect(calls.freed.length, 2);
    });
  }
}
