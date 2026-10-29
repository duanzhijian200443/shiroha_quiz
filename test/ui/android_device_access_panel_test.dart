import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/external/android_device_access.dart';
import 'package:shiroha_quiz/application/external/android_foreground_access.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/application/external/first_party_stage_approval.dart';
import 'package:shiroha_quiz/ui/pages/android_device_access_panel.dart';

final class _Access implements AndroidDeviceAccess {
  final events = StreamController<void>.broadcast(sync: true);
  final choices = <ExternalGenerationMode?>[];
  int enables = 0, disables = 0, leaves = 0;
  ExternalGenerationMode? mode;
  @override
  AndroidDeviceAccessState get state => AndroidDeviceAccessState(
      available: true,
      paired: true,
      policyReady: true,
      phase: AndroidAccessPhase.off,
      generationMode: mode);
  @override
  Stream<void> get changes => events.stream;
  @override
  Future<void> inspect() async {
    events.add(null);
  }

  @override
  Future<void> setGenerationMode(ExternalGenerationMode? value) async {
    choices.add(value);
    mode = value;
    events.add(null);
  }

  @override
  Future<void> enable() async {
    enables++;
  }

  @override
  Future<void> disable() async {
    disables++;
  }

  @override
  Future<void> cancelPending() async {
    leaves++;
  }

  @override
  FirstPartyStageApprovalView? openStageApprovalView() => null;
  @override
  Future<void> pair() async {}
  @override
  void confirmPairing() {}
  @override
  Future<void> observeFlutter(bool resumed) async {}
  @override
  Future<void> close() => events.close();
}

void main() {
  testWidgets(
      'opening preserves READ; first generation choice is review and direct is independent',
      (tester) async {
    final access = _Access();
    await tester.pumpWidget(
        MaterialApp(home: AndroidDeviceAccessPanel(access: access)));
    await tester.pumpAndSettle();
    expect(access.choices, isEmpty);
    expect(access.enables, 0);
    expect(
        tester
            .widget<SwitchListTile>(find.byKey(const Key('android-direct')))
            .onChanged,
        isNull);
    await tester.ensureVisible(find.byKey(const Key('android-generation')));
    await tester.tap(find.byKey(const Key('android-generation')));
    await tester.pumpAndSettle();
    expect(access.choices, [ExternalGenerationMode.review]);
    expect(
        tester
            .widget<SwitchListTile>(find.byKey(const Key('android-direct')))
            .value,
        isFalse);
    await tester.ensureVisible(find.byKey(const Key('android-direct')));
    await tester.tap(find.byKey(const Key('android-direct')));
    await tester.pumpAndSettle();
    expect(access.choices,
        [ExternalGenerationMode.review, ExternalGenerationMode.direct]);
    expect(access.enables, 0);
    await tester.pumpWidget(const SizedBox());
    expect(access.leaves, 1);
    expect(access.disables, 0);
    await access.close();
  });
  testWidgets(
      'legacy confirm stays explicit and local inbox works with access off',
      (tester) async {
    final access = _Access()..mode = ExternalGenerationMode.confirm;
    var reviews = 0;
    await tester.pumpWidget(MaterialApp(
        home: AndroidDeviceAccessPanel(
            access: access, onOpenReview: () => reviews++)));
    await tester.pumpAndSettle();
    expect(find.text('保留逐次发布确认'), findsOneWidget);
    expect(access.choices, isEmpty);
    await tester.ensureVisible(find.byKey(const Key('android-review')));
    await tester.tap(find.byKey(const Key('android-review')));
    expect(reviews, 1);
    expect(access.enables, 0);
    await tester.pumpWidget(const SizedBox());
    await access.close();
  });
}
