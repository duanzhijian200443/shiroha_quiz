import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/external/external_credential_association.dart';
import 'package:shiroha_quiz/composition/android_device_foundation.dart';
import 'package:shiroha_quiz/data/external/android_native_association_backend.dart';

final class Calls implements AndroidNativeCalls {
  final methods = <String>[];
  Object? reply;
  bool deny = false;
  @override
  Future<Object?> invoke(String method,
      [Map<String, Object?>? arguments]) async {
    methods.add(method);
    if (deny) throw PlatformException(code: 'runtime_not_authorized');
    return reply;
  }
}

void main() {
  test(
      'native entry requires the explicit dedicated Debug artifact; no Service',
      () {
    expect(File('lib/main.dart').readAsStringSync(),
        isNot(contains('android_device_foundation')));
    final activity = File(
            'android/app/src/main/kotlin/com/example/shiroha_quiz/MainActivity.kt')
        .readAsStringSync();
    expect(activity,
        contains('!BuildConfig.DEBUG || !BuildConfig.ANDROID_READ_VALIDATION'));
    expect(activity,
        contains('packageName != "com.example.shiroha_quiz.androidread"'));
    expect(activity, isNot(contains('DeviceTlsEndpoint')));
    expect(File('android/app/src/main/AndroidManifest.xml').readAsStringSync(),
        isNot(contains('<service')));
  });
  test('construction and inactive close never acquire Native resources',
      () async {
    final calls = Calls();
    final root = AndroidDeviceFoundation(
        native: calls, elapsed: () => Duration.zero, nowUtcMs: () => 1);
    expect(AndroidDeviceFoundation.runtimeAvailable, isFalse);
    expect(calls.methods, isEmpty);
    await root.close();
    expect(calls.methods, isEmpty);
  });
  test('Native refusal permanently invalidates this backend', () async {
    final calls = Calls()..deny = true;
    final backend = AndroidNativeAssociationBackend(calls);
    await expectLater(
        backend.begin(), throwsA(isA<ExternalCredentialException>()));
    expect(backend.isCurrent, isFalse);
    calls.deny = false;
    await expectLater(
        backend.begin(), throwsA(isA<ExternalCredentialException>()));
    expect(calls.methods, ['associationBegin']);
  });
  test('malformed Native reply is never treated as an empty store', () async {
    final calls = Calls()..reply = {'lease': 1, 'plaintext': 'not-bytes'};
    final backend = AndroidNativeAssociationBackend(calls);
    await expectLater(
        backend.begin(), throwsA(isA<ExternalCredentialException>()));
    expect(backend.isCurrent, isFalse);
  });
}
