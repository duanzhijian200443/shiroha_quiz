import 'dart:ffi';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/external/native/external_native_bindings.dart';
import 'package:shiroha_quiz/data/external/native/windows_external_native.dart';
import 'package:shiroha_quiz/data/external/native/windows_peer_certificate_policy.dart';
import 'external_native_test_support.dart';

class OfflinePeerCalls
    implements ExternalNativeCalls, ExternalNativePeerPolicyCalls {
  final memory = FakeExternalNativeCalls();
  int status = 0, calls = 0;
  bool missing = false;
  final roles = <int>[];
  @override
  int abiVersion() => memory.version;
  @override
  Pointer<Uint8> allocate(int capacity) => memory.allocate(capacity);
  @override
  void free(Pointer<Uint8> buffer) {
    expect(buffer.asTypedList(memory.allocations[buffer.address]!),
        everyElement(0));
    memory.free(buffer);
  }

  @override
  int peerCertificatePolicy(
      int version, Pointer<Uint8> der, int length, int role) {
    expect(version, 3);
    expect(length, inInclusiveRange(1, 16384));
    roles.add(role);
    calls++;
    if (missing) throw ArgumentError('missing optional symbol');
    return status;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  test(
      'loaded Native supplies peer policy over the same calls without eager security execution',
      () {
    final calls = OfflinePeerCalls();
    final native = WindowsExternalNative.openForTesting(
        windows: true,
        executable: r'C:\offline\app.exe',
        exists: (_) => true,
        load: (_) => calls);
    final policy = native.peerCertificatePolicy;
    expect(calls.calls, 0);
    policy.check(Uint8List.fromList([1]), TlsPeerRole.client);
    expect(calls.calls, 1);
    expect(calls.roles, [2]);
    calls.missing = true;
    expect(() => policy.check(Uint8List.fromList([1]), TlsPeerRole.server),
        throwsA(isA<ExternalNativeException>()));
    expect(calls.memory.allocations, isEmpty);
  });
  test('certificate-only ABI, bounded public copies, roles and reverse release',
      () {
    final calls = OfflinePeerCalls();
    final policy = WindowsPeerCertificatePolicy(calls);
    expect(calls.calls, 0);
    for (final role in TlsPeerRole.values) {
      policy.check(Uint8List.fromList([1]), role);
    }
    expect(calls.roles, [1, 2]);
    expect(calls.memory.allocations, isEmpty);
    for (final bytes in [Uint8List(0), Uint8List(16385)]) {
      expect(() => policy.check(bytes, TlsPeerRole.client),
          throwsA(isA<ExternalNativeException>()));
    }
    calls.memory.version = 2;
    expect(() => policy.check(Uint8List(1), TlsPeerRole.client),
        throwsA(isA<ExternalNativeException>()));
    expect(calls.calls, 2);
  });
  test('fixed Native rejection and absent optional capability never accept',
      () {
    final calls = OfflinePeerCalls();
    final policy = WindowsPeerCertificatePolicy(calls);
    // C++ pure policy tests independently flip role/signature/validity/structure
    // and each BC/KU/EKU/SAN field. These statuses are orchestration, not crypto.
    for (final status in [1, 2, 3, 4, 5, 8, 77]) {
      calls.status = status;
      expect(() => policy.check(Uint8List(1), TlsPeerRole.server),
          throwsA(isA<ExternalNativeException>()));
      expect(calls.memory.allocations, isEmpty);
    }
    calls.missing = true;
    expect(() => policy.check(Uint8List(1), TlsPeerRole.client),
        throwsA(isA<ExternalNativeException>()));
    calls.missing = false;
    calls.status = 0;
    calls.memory.throwFree = true;
    expect(() => policy.check(Uint8List(1), TlsPeerRole.client),
        throwsA(isA<ExternalNativeException>()));
    calls.memory.throwFree = false;
    // Fake frees before reporting failure, preserving real ownership accounting.
    for (final address in calls.memory.allocations.keys.toList()) {
      calls.memory.free(Pointer<Uint8>.fromAddress(address));
    }
  });
}
