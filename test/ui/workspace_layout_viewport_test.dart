import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/ui/theme/app_theme.dart';
import 'package:shiroha_quiz/ui/theme/shiroha_theme_tokens.dart';
import 'package:shiroha_quiz/ui/widgets/workspace_layout_viewport.dart';

void main() {
  testWidgets('scaled routes share overlay coordinates and keyboard insets',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(850, 500);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    MediaQueryData? routeMedia;
    var accepted = false;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.themeFor(
          ShirohaAppearance.paperLight
              .copyWith(layout: ShirohaLayoutMode.workspace),
          Brightness.light),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          padding: const EdgeInsets.only(top: 10),
          viewPadding: const EdgeInsets.only(top: 10),
          viewInsets: const EdgeInsets.only(bottom: 100),
          systemGestureInsets: const EdgeInsets.only(left: 8),
        ),
        child: WorkspaceLayoutViewport(child: child!),
      ),
      home: Builder(builder: (context) {
        routeMedia = MediaQuery.of(context);
        return Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Scaled dialog'),
                  content: const TextField(key: ValueKey('dialog-input')),
                  actions: [
                    TextButton(
                      onPressed: () {
                        accepted = true;
                        Navigator.of(context).pop();
                      },
                      child: const Text('Accept'),
                    ),
                  ],
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        );
      }),
    ));
    await tester.pumpAndSettle();
    expect(routeMedia!.size, const Size(1700, 1000));
    expect(routeMedia!.padding.top, 20);
    expect(routeMedia!.viewPadding.top, 20);
    expect(routeMedia!.viewInsets.bottom, 200);
    expect(routeMedia!.systemGestureInsets.left, 16);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    // Measure the painted panel, not Dialog's full-window alignment wrapper.
    final dialog = tester.renderObject<RenderBox>(find
        .descendant(of: find.byType(Dialog), matching: find.byType(Material))
        .first);
    final topLeft = dialog.localToGlobal(Offset.zero);
    final bottomRight =
        dialog.localToGlobal(dialog.size.bottomRight(Offset.zero));
    expect(topLeft.dx, greaterThanOrEqualTo(0));
    expect(topLeft.dy, greaterThanOrEqualTo(10));
    expect(bottomRight.dx, lessThanOrEqualTo(850));
    expect(bottomRight.dy, lessThanOrEqualTo(400));
    expect((topLeft.dx + bottomRight.dx) / 2, closeTo(425, .1));
    await tester.tap(find.byKey(const ValueKey('dialog-input')));
    await tester.enterText(find.byKey(const ValueKey('dialog-input')), '保持输入');
    expect(find.text('保持输入'), findsOneWidget);
    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();
    expect(accepted, isTrue);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mobile layout keeps native size and text scale', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    MediaQueryData? routeMedia;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.themeFor(ShirohaAppearance.paperLight, Brightness.light),
      builder: (context, child) => MediaQuery(
        data:
            MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(1.8)),
        child: WorkspaceLayoutViewport(child: child!),
      ),
      home: Builder(builder: (context) {
        routeMedia = MediaQuery.of(context);
        return const Scaffold(body: Text('Mobile'));
      }),
    ));
    expect(routeMedia!.size, const Size(390, 844));
    expect(routeMedia!.textScaler.scale(16), 28.8);
    expect(tester.takeException(), isNull);
  });
}
