import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/external/external_device_connection.dart';
import 'package:shiroha_quiz/ui/pages/external_device_settings.dart';

final class _Store implements ExternalDeviceSelectionStore {
  _Store(this.value);
  ExternalDeviceSelection value;
  @override
  Future<ExternalDeviceSelection?> readDeviceSelection() async => value;
  @override
  Future<void> saveDeviceSelection(ExternalDeviceSelection next) async =>
      value = next;
  @override
  Future<void> settleDeviceLease(ExternalDeviceLease lease) async {
    lease.requireSettlement(this);
    value = ExternalDeviceSelection(
        target: lease.target, generation: lease.generation);
  }

  @override
  Future<void> acknowledgeDeviceCleanup(
      ExternalDeviceSelection expected, ExternalDeviceSelection next,
      {required bool Function() isCurrent}) async {
    expect(isCurrent(), isTrue);
    expect(value, same(expected));
    value = next;
  }
}

void main() {
  testWidgets('dirty phone requires explicit action and waits for proof',
      (tester) async {
    final phone = ExternalDeviceTarget.android('paired-phone');
    final store = _Store(ExternalDeviceSelection(
        target: phone, generation: 4, needsCleanup: true));
    final proof = Completer<void>();
    var proofs = 0;
    final connection = ExternalDeviceConnection(
        store: store,
        availableTargets: () async => [phone],
        endConnection: () async {},
        verifyRecovery: (_) {
          proofs++;
          return proof.future;
        });
    await connection.load();
    Future<void>? recovery;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ExternalDeviceSettings(
                connection: connection,
                onSelected: (_) => fail('dirty state cannot switch target'),
                onRecover: () {
                  recovery = connection.recover(4, isCurrent: () => true);
                }))));
    expect(proofs, 0);
    final selector = tester.widget<DropdownButton<ExternalDeviceTarget>>(
        find.byKey(const Key('external-device-selector')));
    expect(selector.onChanged, isNull);
    await tester.tap(find.byKey(const Key('external-device-recover')));
    await tester.pump();
    expect(proofs, 1);
    expect(store.value.needsCleanup, true);
    expect(find.text('正在核对上次连接'), findsOneWidget);
    expect(find.byKey(const Key('external-device-recover')), findsNothing);
    proof.complete();
    await recovery;
    await tester.pump();
    expect(find.text('未连接'), findsOneWidget);
    expect(store.value.needsCleanup, false);
    expect(store.value.generation, 5);
    await tester.pumpWidget(const SizedBox());
    await connection.close();
  });

  testWidgets('failed proof keeps visible recovery and original marker',
      (tester) async {
    final phone = ExternalDeviceTarget.android('paired-phone');
    final original = ExternalDeviceSelection(
        target: phone, generation: 9, needsCleanup: true);
    final store = _Store(original);
    final connection = ExternalDeviceConnection(
        store: store,
        availableTargets: () async => [phone],
        endConnection: () async {},
        verifyRecovery: (_) async {
          throw const ExternalDeviceException(
              ExternalDeviceFailure.needsAttention);
        });
    await connection.load();
    Future<void>? recovery;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ExternalDeviceSettings(
                connection: connection,
                onSelected: null,
                onRecover: () {
                  recovery = expectLater(
                      connection.recover(9, isCurrent: () => true),
                      throwsA(isA<ExternalDeviceException>()));
                }))));
    await tester.tap(find.byKey(const Key('external-device-recover')));
    await recovery;
    await tester.pump();
    expect(store.value, same(original));
    expect(find.text('需要处理：上次连接清理未确认'), findsOneWidget);
    expect(find.byKey(const Key('external-device-recover')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await connection.close();
  });

  testWidgets('dirty Windows target offers no Android recovery',
      (tester) async {
    final store = _Store(ExternalDeviceSelection(
        target: const ExternalDeviceTarget.windows(), needsCleanup: true));
    final connection = ExternalDeviceConnection(
        store: store,
        availableTargets: () async => [const ExternalDeviceTarget.windows()],
        endConnection: () async {},
        verifyRecovery: (_) async => fail('no phone proof for Windows'));
    await connection.load();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ExternalDeviceSettings(
                connection: connection, onSelected: null))));
    expect(find.text('需要处理：上次连接清理未确认'), findsOneWidget);
    expect(find.byKey(const Key('external-device-recover')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await connection.close();
  });
}
