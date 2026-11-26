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
      'native entry requires dedicated Debug admission; manifest exposes only non-exported connectedDevice service',
      () {
    expect(File('lib/main.dart').readAsStringSync(),
        isNot(contains('android_device_foundation')));
    final activity = File(
            'android/app/src/main/kotlin/com/example/shiroha_quiz/MainActivity.kt')
        .readAsStringSync();
    expect(activity,
        contains('!BuildConfig.DEBUG || !BuildConfig.ANDROID_READ_VALIDATION'));
    expect(
        activity,
        contains(
            'packageName != BuildConfig.ANDROID_READ_VALIDATION_APPLICATION_ID'));
    final build = File('android/app/build.gradle.kts').readAsStringSync();
    expect(
        build,
        contains(
            'check(!androidLinkIsolationValidation || androidReadValidation)'));
    expect(
        build,
        contains(
            r'buildConfigField("String", "ANDROID_READ_VALIDATION_APPLICATION_ID", "\"\"")'));
    expect(build, contains('com.example.shiroha_quiz.androidread'));
    expect(build, contains('com.example.shiroha_quiz.linkvalidation'));
    expect(build, contains('androidLinkIsolationValidationTag'));
    expect(build, contains('Regex("[a-z][a-z0-9]{0,23}")'));
    final proof = File(
            'android/app/src/debug/kotlin/com/example/shiroha_quiz/external/DeviceNativeProofActivity.kt')
        .readAsStringSync();
    expect(
        proof,
        contains(
            'packageName != BuildConfig.ANDROID_READ_VALIDATION_APPLICATION_ID'));
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(manifest, isNot(contains('sharedUserId')));
    expect(activity, isNot(contains('DeviceTlsEndpoint')));
    expect('<service'.allMatches(manifest).length, 1);
    expect(
        manifest,
        contains(
            'android:name="com.example.shiroha_quiz.external.DeviceReadService"'));
    expect(manifest, contains('android:exported="false"'));
    expect(manifest, contains('android:stopWithTask="true"'));
    expect(
        manifest, contains('android:foregroundServiceType="connectedDevice"'));
    expect(manifest, contains('android.permission.FOREGROUND_SERVICE'));
    expect(manifest,
        contains('android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE'));

    final service = File(
            'android/app/src/main/kotlin/com/example/shiroha_quiz/external/DeviceReadService.kt')
        .readAsStringSync();
    expect(service, contains('START_NOT_STICKY'));
    expect(service, contains('FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE'));

    final tlsStore = File(
            'android/app/src/main/kotlin/com/example/shiroha_quiz/external/DeviceHttpTlsStore.kt')
        .readAsStringSync();
    expect(tlsStore, contains('KeyStore.getInstance("AndroidKeyStore")'));
    expect(tlsStore, contains('KeyInfo::class.java'));
    expect(tlsStore, contains('credentials.seal(pkcs8, "http-leaf-key")'));
    expect(tlsStore, isNot(contains('engine.')));
    expect(tlsStore, isNot(contains('FlutterSecureStorage')));
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
