import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/ui/theme/app_theme.dart';
import 'package:shiroha_quiz/ui/theme/shiroha_theme_tokens.dart';
import 'package:shiroha_quiz/ui/widgets/shiroha_workspace_navigation.dart';

List<SemanticsNode> _nodes(WidgetTester tester) {
  final nodes = <SemanticsNode>[];
  void visit(SemanticsNode node) {
    nodes.add(node);
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  visit(tester
      .binding.renderViews.single.owner!.semanticsOwner!.rootSemanticsNode!);
  return nodes;
}

void _expectAttachedTraversalParents(WidgetTester tester,
    {bool requireOverlay = false}) {
  final data = _nodes(tester).map((node) => node.getSemanticsData()).toList();
  final parents = data
      .map((node) => node.traversalParentIdentifier)
      .whereType<Object>()
      .toSet();
  if (requireOverlay) {
    expect(
        data.where((node) => node.traversalChildIdentifier != null), isNotEmpty,
        reason: 'The tooltip must remain visible and accessible after repair.');
  }
  for (final node in data) {
    if (node.traversalChildIdentifier case final Object identifier) {
      expect(parents, contains(identifier),
          reason: 'Every visible overlay must retain its semantics anchor.');
    }
  }
}

void main() {
  for (final layout in [
    (
      name: 'expanded',
      size: const Size(1440, 1000),
      expanded: true,
      horizontal: false
    ),
    (
      name: 'rail',
      size: const Size(1024, 768),
      expanded: false,
      horizontal: false
    ),
    (
      name: 'horizontal',
      size: const Size(390, 844),
      expanded: false,
      horizontal: true
    ),
  ]) {
    testWidgets(
        '${layout.name} tooltips keep reachable semantics and navigation',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = layout.size;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final semantics = tester.ensureSemantics();
      try {
        var selected = 0;
        await tester.pumpWidget(MaterialApp(
          theme:
              AppTheme.themeFor(ShirohaAppearance.paperLight, Brightness.light),
          home: StatefulBuilder(builder: (context, setState) {
            final navigation = ShirohaWorkspaceNavigation(
              expanded: layout.expanded,
              horizontal: layout.horizontal,
              selectedIndex: selected,
              onSelected: (value) => setState(() => selected = value),
            );
            final pages = IndexedStack(index: selected, children: [
              for (var index = 0; index < 7; index++)
                Center(child: Text('destination-$index')),
            ]);
            return Scaffold(
              body: layout.horizontal
                  ? pages
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                          navigation,
                          Expanded(child: pages),
                        ]),
              bottomNavigationBar: layout.horizontal ? navigation : null,
            );
          }),
        ));
        await tester.pumpAndSettle();
        final mouse =
            await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
        await mouse.addPointer(location: const Offset(-1, -1));
        addTearDown(mouse.removePointer);

        for (final index in [5, 0, 1, 2, 3, 4, 6]) {
          final entry = find.byKey(ValueKey('workspace-nav-$index'));
          await tester.ensureVisible(entry);
          await tester.pumpAndSettle();
          await mouse.moveTo(tester.getCenter(entry));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 250));
          _expectAttachedTraversalParents(tester, requireOverlay: true);
          expect(tester.takeException(), isNull);

          final label = ShirohaWorkspaceNavigation.labels[index];
          final button = _nodes(tester).singleWhere((node) {
            final data = node.getSemanticsData();
            return data.label == label && data.flagsCollection.isButton;
          });
          final data = button.getSemanticsData();
          expect(data.hasAction(ui.SemanticsAction.tap), isTrue);
          expect(data.flagsCollection.isSelected,
              selected == index ? ui.Tristate.isTrue : ui.Tristate.isFalse);

          // Exercise the action available to screen readers, not only pointer taps.
          button.owner!.performAction(button.id, ui.SemanticsAction.tap);
          await tester.pump();
          _expectAttachedTraversalParents(tester);
          await tester.pumpAndSettle();
          expect(selected, index);
          expect(find.text('destination-$index'), findsOneWidget);
          _expectAttachedTraversalParents(tester);
          expect(tester.takeException(), isNull);
          await mouse.moveTo(const Offset(-1, -1));
          await tester.pumpAndSettle();
          _expectAttachedTraversalParents(tester);
        }
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        semantics.dispose();
      }
    });
  }
}
