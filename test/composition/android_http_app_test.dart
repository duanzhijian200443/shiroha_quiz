import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/external/android_foreground_access.dart';
import 'package:shiroha_quiz/application/external/android_http_access.dart';
import 'package:shiroha_quiz/composition/android_http_app.dart';
import 'package:shiroha_quiz/data/repositories/backup_database_authority.dart';
import 'package:uuid/uuid.dart';

import '../application/generated_question/generated_test_support.dart';
import '../data/external/android_native_backend_test.dart'
    show AndroidHttpCertificateCalls;
import '../mcp/fixtures/first_party_app_integration_cases.dart'
    show FirstPartyAppHarness;

const _channel = MethodChannel('shiroha/android_device_foundation');

Matcher _accessFailure(String code) => throwsA(
    isA<AndroidHttpAccessException>().having((e) => e.code, 'code', code));

const _address = '192.168.1.10';

Map<String, Object?> _foregroundStatus(int sequence) => {
      'runtimeAvailable': true,
      'http': true,
      'observation': {
        'sequence': sequence,
        'elapsedMs': sequence,
        'resumed': true,
        'focused': true,
        'interactive': true,
        'unlocked': true,
        'visible': true,
        'network': 'synthetic-wifi',
        'address': _address,
        'notificationsAllowed': true,
        'backgroundRead': true,
      },
    };

final class _DirectLoopbackHttpOverrides extends HttpOverrides {}

final class _NativeHttp {
  final calls = <String>[];
  final certificates = AndroidHttpCertificateCalls();
  int _sequence = 0, _leases = 0;
  int? activeLease;
  Uint8List? _associations;
  Future<void> Function()? beforeStatus, beforeAssociationClose, beforeStop;
  bool stopAcknowledged = true;

  Future<Object?> handle(MethodCall call) async {
    calls.add(call.method);
    switch (call.method) {
      case 'status':
        await beforeStatus?.call();
        return _foregroundStatus(++_sequence);
      case 'identity':
        return {
          'installationId': '30000000-0000-4000-8000-000000000001',
          'deviceId': 'offline-phone',
        };
      case 'associationBegin':
        expect(activeLease, isNull);
        final lease = activeLease = ++_leases;
        return {'lease': lease, 'plaintext': _associations};
      case 'associationCommit':
        expect(call.arguments['lease'], activeLease);
        _associations =
            Uint8List.fromList(call.arguments['plaintext'] as Uint8List);
        return true;
      case 'associationClose':
        expect(call.arguments['lease'], activeLease);
        await beforeAssociationClose?.call();
        activeLease = null;
        return true;
      case 'readServiceStart':
      case 'readServiceActivate':
        return true;
      case 'readServiceStop':
        await beforeStop?.call();
        return stopAcknowledged;
      case final method when method.startsWith('http'):
        return certificates.invoke(
            method, (call.arguments as Map?)?.cast<String, Object?>());
      default:
        throw StateError('Unexpected test channel method');
    }
  }
}

Future<Map<String, dynamic>> _openContext(Uri endpoint, String token) async {
  final client = HttpOverrides.runWithHttpOverrides(() {
    return HttpClient()..findProxy = (_) => 'DIRECT';
  }, _DirectLoopbackHttpOverrides());
  try {
    final request = await client.postUrl(endpoint.replace(
        scheme: 'http', host: InternetAddress.loopbackIPv4.address));
    request.headers
      ..set(HttpHeaders.hostHeader, endpoint.authority)
      ..set(HttpHeaders.acceptHeader, 'application/json, text/event-stream')
      ..set(HttpHeaders.authorizationHeader, 'Bearer $token')
      ..contentType = ContentType.json
      ..set('mcp-protocol-version', '2026-07-28')
      ..set('mcp-method', 'tools/call')
      ..set('mcp-name', 'open_context');
    request.write(jsonEncode({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'tools/call',
      'params': {
        'name': 'open_context',
        'arguments': {},
        '_meta': {
          'io.modelcontextprotocol/protocolVersion': '2026-07-28',
          'io.modelcontextprotocol/clientCapabilities': <String, Object?>{},
        },
      },
    }));
    final response = await request.close();
    final body = await utf8.decoder.bind(response).join();
    expect(response.statusCode, HttpStatus.ok);
    final result = (jsonDecode(body) as Map<String, dynamic>)['result'] as Map;
    return (result['structuredContent'] as Map).cast<String, dynamic>();
  } finally {
    client.close(force: true);
  }
}

void main() {
  initializeGeneratedTests();
  final messenger =
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;

  test('leaving during the initial status read cancels Enable', () async {
    final entered = Completer<void>();
    final status = Completer<Map<String, Object?>>();
    final calls = <String>[];
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call.method);
      if (call.method != 'status') {
        throw PlatformException(code: 'unexpected_native_call');
      }
      entered.complete();
      return status.future;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(_channel, null));
    final app = AndroidHttpApp(
      createIntegration: () => throw StateError('Unexpected App attachment'),
      applicationCurrent: () => true,
      mintId: () => throw StateError('Unexpected identity allocation'),
    );
    addTearDown(app.close);

    final enable = app.enable(AndroidAccessDuration.fiveMinutes,
        background: true, continueWhileLocked: false);
    final cancelled = expectLater(enable, _accessFailure('enable_cancelled'));
    await entered.future;
    expect(app.state.phase, AndroidAccessPhase.preparing);
    await app.cancelPending();
    status.complete(_foregroundStatus(1));
    await cancelled;

    expect(calls, ['status']);
    expect(app.state.available, isTrue);
    expect(app.state.phase, AndroidAccessPhase.off);
    expect(app.state.endpoint, isNull);
  });

  group('Android HTTP App lifecycle', () {
    late FirstPartyAppHarness integration;
    late _NativeHttp native;
    late AndroidHttpApp app;
    late List<int> boundPorts;

    setUp(() async {
      integration = FirstPartyAppHarness(androidHttpProfile: true);
      await integration.open(attach: false);
      addTearDown(integration.close);
      native = _NativeHttp();
      messenger.setMockMethodCallHandler(_channel, native.handle);
      addTearDown(() => messenger.setMockMethodCallHandler(_channel, null));
      boundPorts = [];
      app = AndroidHttpApp(
        createIntegration: () => integration.integration,
        applicationCurrent: () => integration.files.s.h.db.isOpen,
        mintId: const Uuid().v4,
        bindListener: ({
          required ipv4Address,
          required port,
          required certificateChainPemBytes,
          required privateKeyPemOrPkcs8Bytes,
        }) async {
          expect(ipv4Address, _address);
          expect(port, 17443);
          expect(certificateChainPemBytes, isNotEmpty);
          expect(privateKeyPemOrPkcs8Bytes, isNotEmpty);
          final listener =
              await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          boundPorts.add(listener.port);
          return listener;
        },
      );
      addTearDown(() async {
        if (native.stopAcknowledged) await app.close();
      });
    });

    Future<void> enable() => app.enable(AndroidAccessDuration.fiveMinutes,
        background: true, continueWhileLocked: false);

    Future<void> expectListenerClosed() => expectLater(
        Socket.connect(InternetAddress.loopbackIPv4, boundPorts.single),
        throwsA(isA<SocketException>()));

    SqliteBackupDatabaseAuthority backupAuthority() =>
        SqliteBackupDatabaseAuthority(
            databaseHelper: integration.files.s.h.helper,
            beforeClose: app.close);

    test('cold start stays dormant and inspection only reads status and CA',
        () async {
      expect(native.calls, isEmpty);
      expect(app.state.phase, AndroidAccessPhase.off);
      expect(app.state.endpoint, isNull);
      expect(integration.integration.hasAttachment, isFalse);

      await app.inspect();
      expect(native.calls, ['status', 'httpCaRead']);
      expect(app.state.privateWifi, isTrue);
      expect(app.state.endpoint, isNull);
      expect(integration.integration.hasAttachment, isFalse);
      expect(boundPorts, isEmpty);
    });

    test('no eligible clients shuts down the original listener and service',
        () async {
      final admitted = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      native.beforeAssociationClose = () async {
        admitted.complete();
        await release.future;
      };
      final enabling = enable();
      final refused =
          expectLater(enabling, _accessFailure('no_eligible_clients'));
      await admitted.future;
      expect(native.activeLease, isNotNull);
      expect(app.state.phase, AndroidAccessPhase.preparing);
      expect(app.state.endpoint, isNull);
      release.complete();
      await refused;

      expect(native.activeLease, isNull);
      expect(app.state.phase, AndroidAccessPhase.off);
      expect(app.state.endpoint, isNull);
      expect(native.calls.where((method) => method.startsWith('readService')),
          ['readServiceStart', 'readServiceActivate', 'readServiceStop']);
      await expectListenerClosed();
    });

    test('navigation preserves READY until the original service withdraws',
        () async {
      final token = await app.addClient('Synthetic client');
      await enable();
      final endpoint = app.state.endpoint;
      expect(
          endpoint,
          Uri(
              scheme: 'https',
              host: _address,
              port: boundPorts.single,
              path: '/mcp'));
      await expectLater(enable(), _accessFailure('busy'));
      await app.cancelPending();
      expect(app.state.endpoint, endpoint);
      final context = await _openContext(endpoint!, token);
      expect(context['profileVersion'], 3);
      expect(context['error'], isNull);
      expect((context['data'] as Map)['contextRef'], isA<String>());

      final withdrawn = app.changes
          .firstWhere((_) => app.state.phase == AndroidAccessPhase.off);
      await messenger.handlePlatformMessage(
          _channel.name,
          const StandardMethodCodec().encodeMethodCall(
              const MethodCall('readServiceWithdrawn', <String, Object?>{})),
          (_) {});
      await withdrawn;
      expect(app.state.endpoint, isNull);
      expect(native.calls.where((method) => method == 'readServiceStop'),
          hasLength(1));
      await expectListenerClosed();
    });

    test('B0 waits for original service and local operation before closing DB',
        () async {
      await app.addClient('Synthetic client');
      await enable();
      final statusEntered = Completer<void>();
      final statusRelease = Completer<void>();
      final stopEntered = Completer<void>();
      final stopRelease = Completer<void>();
      addTearDown(() {
        if (!statusRelease.isCompleted) statusRelease.complete();
        if (!stopRelease.isCompleted) stopRelease.complete();
      });
      native.beforeStatus = () async {
        statusEntered.complete();
        await statusRelease.future;
      };
      native.beforeStop = () async {
        stopEntered.complete();
        await stopRelease.future;
      };
      final operation = app.addClient('Pending client');
      final refused =
          expectLater(operation, _accessFailure('foreground_required'));
      await statusEntered.future;
      final closingEvents = app.changes.drain<void>();
      var databaseClosed = false;
      final close = backupAuthority().closeProduction().then((_) {
        databaseClosed = true;
      });
      expect(app.state.endpoint, isNull);
      await stopEntered.future;
      expect(databaseClosed, isFalse);
      expect(integration.controls.isCurrent, isTrue);
      await expectListenerClosed();

      stopRelease.complete();
      await Future<void>.delayed(Duration.zero);
      expect(databaseClosed, isFalse);
      expect(integration.controls.isCurrent, isTrue);
      expect(integration.files.s.h.db.isOpen, isTrue);

      statusRelease.complete();
      await refused;
      await close;
      await closingEvents;
      expect(databaseClosed, isTrue);
      expect(integration.controls.isCurrent, isFalse);
      expect(integration.files.s.h.db.isOpen, isFalse);
      expect(native.activeLease, isNull);
    });

    test('unconfirmed stop latches recovery and B0 leaves the DB open',
        () async {
      await app.addClient('Synthetic client');
      await enable();
      native.stopAcknowledged = false;
      final close = backupAuthority().closeProduction();
      expect(app.state.endpoint, isNull);
      await expectLater(close, _accessFailure('settlement_unknown'));
      expect(app.state.phase, AndroidAccessPhase.recovery);
      expect(integration.files.s.h.db.isOpen, isTrue);
      expect(integration.controls.isCurrent, isFalse);
      expect(native.activeLease, isNull);
      await expectLater(app.close(), _accessFailure('settlement_unknown'));
      expect(native.calls.where((method) => method == 'readServiceStop'),
          hasLength(1));
      await expectListenerClosed();
    });
  });
}
