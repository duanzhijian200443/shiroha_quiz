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
  final fileChoices = <bool>[];
  final statisticsChoices = <bool>[];
  bool statistics = false;
  bool files = false, allContent = true, hasFileScope = false;
  int enables = 0, disables = 0, leaves = 0;
  ExternalGenerationMode? mode;
  @override
  AndroidDeviceAccessState get state => AndroidDeviceAccessState(
      available: true,
      paired: true,
      policyReady: true,
      fileContentAllowed: files,
      studyStatisticsAllowed: statistics,
      allContent: allContent,
      hasFileScope: hasFileScope,
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
  Future<void> setFileContentAllowed(bool allowed) async {
    fileChoices.add(allowed);
    files = allowed;
    events.add(null);
  }

  @override
  Future<void> setStudyStatisticsAllowed(bool allowed) async {
    statisticsChoices.add(allowed);
    statistics = allowed;
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
  testWidgets('statistics opt-in is independent of files and generation',
      (tester) async {
    final access = _Access()..mode = ExternalGenerationMode.direct;
    await tester.pumpWidget(
        MaterialApp(home: AndroidDeviceAccessPanel(access: access)));
    await tester.pumpAndSettle();
    final control = find.byKey(const Key('android-study-statistics'));
    expect(tester.widget<SwitchListTile>(control).value, false);
    await tester.ensureVisible(control);
    await tester.tap(control);
    await tester.pumpAndSettle();
    expect(access.statisticsChoices, [true]);
    expect(access.fileChoices, isEmpty);
    expect(access.choices, isEmpty);
    expect(access.mode, ExternalGenerationMode.direct);
    expect(access.enables, 0);
    await tester.pumpWidget(const SizedBox());
    await access.close();
  });

  testWidgets('file consent describes actual scope and preserves direct mode',
      (tester) async {
    final access = _Access()..mode = ExternalGenerationMode.direct;
    await tester.pumpWidget(
        MaterialApp(home: AndroidDeviceAccessPanel(access: access)));
    await tester.pumpAndSettle();
    expect(access.fileChoices, isEmpty);
    expect(find.textContaining('现有及之后加入的 File Library'), findsOneWidget);
    final control = find.byKey(const Key('android-file-content'));
    await tester.ensureVisible(control);
    await tester.tap(control);
    await tester.pumpAndSettle();
    expect(access.fileChoices, [true]);
    expect(access.choices, isEmpty);
    expect(access.mode, ExternalGenerationMode.direct);
    expect(access.enables, 0);
    await tester.tap(control);
    await tester.pumpAndSettle();
    expect(access.fileChoices, [true, false]);
    access.allContent = false;
    access.events.add(null);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(control).onChanged, isNull);
    expect(find.textContaining('原策略没有文件范围'), findsOneWidget);
    access.hasFileScope = true;
    access.events.add(null);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(control).onChanged, isNotNull);
    expect(find.textContaining('仅覆盖原策略中明确授权的文件范围'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await access.close();
  });
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
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('android-review')));
    expect(reviews, 1);
    expect(access.enables, 0);
    await tester.pumpWidget(const SizedBox());
    await access.close();
  });
}
