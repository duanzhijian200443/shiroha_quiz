import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/external/external_credential_association.dart';
import 'package:shiroha_quiz/composition/android_device_foundation.dart';
import 'package:shiroha_quiz/data/external/android_http_tls.dart';
import 'package:shiroha_quiz/data/external/android_native_association_backend.dart';
import 'package:shiroha_quiz/data/external/external_certificate_der.dart';

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

final class AndroidHttpCertificateCalls implements AndroidNativeCalls {
  final rootKey = Uint8List.fromList([4, ...List.filled(64, 1)]);
  final leafKey = Uint8List.fromList([4, ...List.filled(64, 2)]);
  Uint8List? root, leaf;
  String? address;
  int? expiresAt;
  int leafPublications = 0;

  @override
  Future<Object?> invoke(String method,
      [Map<String, Object?>? arguments]) async {
    switch (method) {
      case 'httpCaEnsure':
        return {'publicKey': rootKey, 'nonExportable': true};
      case 'httpCaRead':
        return root;
      case 'httpCaSignTbs':
        return Uint8List.fromList([0x30, 6, 2, 1, 1, 2, 1, 1]);
      case 'httpCaStore':
        root = arguments!['caDer'] as Uint8List;
        return true;
      case 'httpLeafGenerateKey':
        return leafKey;
      case 'httpLeafStore':
        address = arguments!['ipv4'] as String;
        expiresAt = arguments['expiresAtUtcMs'] as int;
        leaf = arguments['leafDer'] as Uint8List;
        final certificate = ExternalCertificateDer.inspect(
          leaf!,
          role: ExternalCertificateRole.server,
          expectedIpv4San: address,
          expectedSubjectKeyIdentifier:
              ExternalCertificateDer.computeKeyIdentifier(leafKey),
          expectedAuthorityKeyIdentifier:
              ExternalCertificateDer.computeKeyIdentifier(rootKey),
          expectedValidityDays: 90,
        );
        expect(expiresAt, certificate.notAfter.millisecondsSinceEpoch);
        leafPublications++;
        return true;
      case 'httpLeafDiscard':
        return true;
      case 'httpLeafOpen':
        if (leaf == null) throw PlatformException(code: 'pairing_required');
        return {
          'caDer': root,
          'leafDer': leaf,
          'ipv4': address,
          'expiresAtUtcMs': expiresAt,
          'leafPrivateKeyPkcs8':
              Uint8List.fromList([0x30, 0]).asUnmodifiableView(),
        };
      default:
        throw StateError('unexpected certificate method');
    }
  }
}

void main() {
  test(
      'HTTP certificate expiry uses the signed whole second and an IP change retains the CA',
      () async {
    final calls = AndroidHttpCertificateCalls();
    final now = DateTime.utc(2026, 11, 27, 12, 0, 4, 567, 89);
    final tls = AndroidHttpTls(calls, now: () => now);
    final first = await tls.prepare('192.168.1.10');
    first.privateKey.fillRange(0, first.privateKey.length, 0);
    expect(first.privateKey, [0, 0]);
    expect(calls.expiresAt! % 1000, 0);
    expect(calls.leafPublications, 1);
    await tls.prepare('192.168.1.10');
    expect(calls.leafPublications, 1);
    final second = await tls.prepare('192.168.1.11');
    expect(calls.address, '192.168.1.11');
    expect(calls.leafPublications, 2);
    expect(second.root.fingerprint, first.root.fingerprint);
  });
  test(
      'default Android admits HTTP, legacy needs Debug, and READ service is private',
      () {
    expect(File('lib/main.dart').readAsStringSync(),
        isNot(contains('android_device_foundation')));
    final activity = File(
            'android/app/src/main/kotlin/com/example/shiroha_quiz/MainActivity.kt')
        .readAsStringSync();
    expect(activity,
        contains('BuildConfig.DEBUG && BuildConfig.ANDROID_READ_VALIDATION'));
    expect(
        activity,
        contains(
            'packageName == BuildConfig.ANDROID_READ_VALIDATION_APPLICATION_ID'));
    expect(activity, contains('httpOnly = !legacyValidationSelected()'));
    expect(activity, contains('Build.VERSION.SDK_INT < 29'));
    final channel = File(
            'android/app/src/main/kotlin/com/example/shiroha_quiz/external/DeviceFoundationChannel.kt')
        .readAsStringSync();
    final methods = channel.split('val httpMethods = setOf(').last;
    expect(methods, contains('"httpLeafOpen"'));
    expect(methods, contains('"readServiceActivate"'));
    expect(methods, isNot(contains('"linkOpen"')));
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
