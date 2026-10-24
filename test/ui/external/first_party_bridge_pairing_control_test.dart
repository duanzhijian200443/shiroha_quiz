import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/external/first_party_external_credentials.dart';
import 'package:shiroha_quiz/ui/pages/first_party_bridge_pairing_control.dart';

const _id = '0123456789abcdef0123456789abcdef';
final _initial = 'a' * 64;
final _completed = 'b' * 64;
const _privateDiagnostic = 'fixture diagnostic must not escape';

// Presentation-only fake; actual P27/codec coverage stays in windows_pairing_test.
class _BridgePort implements FirstPartyBridgePairingPort {
  bool begun = false, trusted = false, proof = false, completed = false;
  bool closed = false, saved = false, failDisplay = false, failImport = false;
  int begins = 0, confirms = 0, saves = 0, closes = 0;
  String initial = _initial;
  String? importedTrust, importedCompletion;
  Completer<void>? pendingImport, pendingClose;

  @override
  FirstPartyBridgePairingDisplay display() {
    if (failDisplay) throw StateError(_privateDiagnostic);
    return FirstPartyBridgePairingDisplay(
      submissionId: begun && !closed ? _id : null,
      initialDigest: trusted && !closed ? initial : null,
      completionDigest: completed && !closed ? _completed : null,
      revision: completed && !closed ? 17 : null,
      proofPublished: proof && !closed,
      closed: closed,
      pinSaved: saved,
    );
  }

  @override
  void beginEnrollment(
      {required String displayLabel, required String clientBuild}) {
    begins++;
    begun = true;
  }

  @override
  Future<void> importTrust(String publicData) async {
    importedTrust = publicData;
    await pendingImport?.future;
    if (failImport) throw StateError(_privateDiagnostic);
    trusted = true;
  }

  @override
  void confirmInitial(String comparedDigest) {
    expect(comparedDigest, initial);
    confirms++;
    proof = true;
  }

  @override
  Future<void> importCompletion(String publicData) async {
    importedCompletion = publicData;
    completed = true;
  }

  @override
  void confirmCompletion(String comparedDigest, int comparedRevision) {
    expect(comparedDigest, _completed);
    expect(comparedRevision, 17);
    saves++;
    saved = true;
    closed = true;
  }

  @override
  Future<void> close() {
    closes++;
    closed = true;
    return pendingClose?.future ?? Future<void>.value();
  }
}

Finder _field(String label) => find.byWidgetPredicate(
    (widget) => widget is TextField && widget.decoration?.labelText == label);

Future<void> _tap(WidgetTester tester, String label) async {
  final target = find.text(label);
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pump();
}

FilledButton _button(WidgetTester tester, String label) =>
    tester.widget<FilledButton>(find.widgetWithText(FilledButton, label));

Future<void> _mount(WidgetTester tester, _BridgePort port) async {
  await tester.binding.setSurfaceSize(const Size(1000, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  addTearDown(() => tester.pumpWidget(const SizedBox()));
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: FirstPartyBridgePairingControl(port: port)),
  ));
}

Future<void> _trust(WidgetTester tester) async {
  await _tap(tester, '开始配对');
  await tester.enterText(_field('粘贴 App Trust 公共 JSON'), '["public trust"]');
  await tester.pump();
  await _tap(tester, '导入 Trust');
}

void main() {
  testWidgets(
      'Bridge UI requires two separate comparisons and copies original ID',
      (tester) async {
    final port = _BridgePort();
    Object? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = call.arguments;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await _mount(tester, port);
    expect(port.begins, 0);
    await _trust(tester);
    expect(port.begins, 1);
    expect(port.importedTrust, '["public trust"]');
    expect(find.text(_id), findsOneWidget);
    await _tap(tester, '复制 Submission ID');
    expect(copied, {'text': _id});
    expect(find.text(_initial), findsOneWidget);
    expect(port.confirms, 0);
    expect(port.saves, 0);
    expect(_button(tester, '确认初始比较并发布 Proof').onPressed, isNull);
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await _tap(tester, '确认初始比较并发布 Proof');
    expect(port.confirms, 1);
    expect(port.saves, 0);
    await tester.enterText(
        _field('粘贴 App Completion 公共 JSON'), '["public completion"]');
    await tester.pump();
    await _tap(tester, '导入 Completion');
    expect(port.importedCompletion, '["public completion"]');
    expect(find.text(_completed), findsOneWidget);
    expect(find.text('实际 Revision：17'), findsOneWidget);
    expect(port.saves, 0);
    expect(tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isFalse);
    expect(_button(tester, '确认完成比较并保存凭据').onPressed, isNull);
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await _tap(tester, '确认完成比较并保存凭据');
    expect(port.saves, 1);
    expect(port.closes, 1);
    expect(find.text(_id), findsNothing);
    expect(find.text(_initial), findsNothing);
    expect(find.text(_completed), findsNothing);
    expect(find.text('开始配对'), findsNothing);
    expect(find.textContaining('凭据已保存'), findsOneWidget);
  });

  testWidgets('refresh clears old comparison and withdraws expired data safely',
      (tester) async {
    final port = _BridgePort();
    await _mount(tester, port);
    await _trust(tester);
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    expect(_button(tester, '确认初始比较并发布 Proof').onPressed, isNotNull);
    port.initial = 'c' * 64;
    await tester.pump(const Duration(seconds: 1));
    expect(find.text(_initial), findsNothing);
    expect(_button(tester, '确认初始比较并发布 Proof').onPressed, isNull);
    port.failDisplay = true;
    await tester.pump(const Duration(seconds: 1));
    expect(find.text(port.initial), findsNothing);
    expect(find.text(_id), findsNothing);
    expect(find.textContaining('配对不可用或已过期'), findsOneWidget);
    expect(find.textContaining(_privateDiagnostic), findsNothing);
    expect(port.closes, 1);
    expect(port.confirms, 0);
    port.failDisplay = false;
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('开始配对'), findsNothing);
  });

  for (final end in ['cancel', 'dispose']) {
    testWidgets(
        '$end closes once and suppresses late import and close callbacks',
        (tester) async {
      final port = _BridgePort()
        ..pendingImport = Completer<void>()
        ..pendingClose = Completer<void>();
      await _mount(tester, port);
      await _trust(tester);
      expect(port.importedTrust, isNotNull);
      if (end == 'cancel') {
        await _tap(tester, '取消配对');
        expect(find.text(_id), findsNothing);
      }
      await tester.pumpWidget(const SizedBox());
      expect(port.closes, 1);
      port.pendingImport!.complete();
      port.pendingClose!.completeError(StateError(_privateDiagnostic));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(port.confirms, 0);
      expect(port.saves, 0);
      expect(port.closes, 1);
      expect(find.text(_initial), findsNothing);
    });
  }

  testWidgets(
      'bounded inputs and safe import failure never enable confirmation',
      (tester) async {
    final port = _BridgePort()..failImport = true;
    await _mount(tester, port);
    await tester.enterText(_field('显示名称'), '界' * 30);
    expect(tester.widget<TextField>(_field('显示名称')).controller!.text,
        'Shiroha Bridge');
    await _tap(tester, '开始配对');
    await tester.enterText(_field('粘贴 App Trust 公共 JSON'), 'x' * 4097);
    await tester.pump();
    expect(_button(tester, '导入 Trust').onPressed, isNull);
    expect(port.importedTrust, isNull);
    await tester.enterText(_field('粘贴 App Trust 公共 JSON'), '界' * 1366);
    await tester.pump();
    expect(_button(tester, '导入 Trust').onPressed, isNull);
    await tester.enterText(_field('粘贴 App Trust 公共 JSON'), '["untrusted"]');
    await tester.pump();
    await _tap(tester, '导入 Trust');
    expect(find.textContaining(_privateDiagnostic), findsNothing);
    expect(find.textContaining('配对不可用或已过期'), findsOneWidget);
    expect(port.closes, 1);
    expect(port.confirms, 0);
  });

  testWidgets('a page over a live port displays it without a new enrollment',
      (tester) async {
    final port = _BridgePort()..begun = true;
    await _mount(tester, port);
    expect(port.begins, 0);
    expect(find.text('开始配对'), findsNothing);
    expect(find.text(_id), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(port.begins, 0);
  });
}
