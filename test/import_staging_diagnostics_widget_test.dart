import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/ui/pages/import_staging_screen.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await DatabaseHelper.deleteDatabaseFile();
    await DatabaseHelper.instance.database;
  });

  Widget createWidgetUnderTest({
    required List<Map<String, dynamic>> parsedQuestions,
    List<String>? warnings,
    Map<String, dynamic>? diagnostics,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: ImportStagingScreen(
          parsedQuestions: parsedQuestions,
          warnings: warnings,
          diagnostics: diagnostics,
        ),
      ),
    );
  }

  testWidgets('ImportStagingScreen shows no banner when diagnostics are empty',
      (WidgetTester tester) async {
    final parsed = [
      {
        'type': 0,
        'content': 'Question 1',
        'standard_answer': 'A',
      }
    ];

    await tester.runAsync(() async {
      await tester.pumpWidget(createWidgetUnderTest(parsedQuestions: parsed));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.textContaining('条记录'), findsNothing);
    });
  });

  testWidgets('ImportStagingScreen shows warning banner and opens details',
      (WidgetTester tester) async {
    final parsed = [
      {
        'type': 0,
        'content': 'Question 1',
        'standard_answer': 'A',
      }
    ];

    await tester.runAsync(() async {
      await tester.pumpWidget(createWidgetUnderTest(
        parsedQuestions: parsed,
        warnings: ['Markdown image not found', 'Weak formatting'],
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Verify warning banner title
      expect(find.text('解析有注意事项 (2 条记录)'), findsOneWidget);

      // Tap on details button
      await tester.tap(find.text('查看详情'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Verify details sheet is opened and items are displayed
      expect(find.text('导入诊断详情'), findsOneWidget);
      expect(find.text('Markdown image not found'), findsOneWidget);
      expect(find.text('Weak formatting'), findsOneWidget);

      // Close bottom sheet
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    });
  });

  testWidgets('ImportStagingScreen shows error banner for PDF crash',
      (WidgetTester tester) async {
    final parsed = [
      {
        'type': 0,
        'content': 'Question 1',
        'standard_answer': 'A',
      }
    ];

    await tester.runAsync(() async {
      await tester.pumpWidget(createWidgetUnderTest(
        parsedQuestions: parsed,
        diagnostics: {
          'pdf_render': {'status': 'crash', 'error': 'Corrupt stream'},
        },
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Verify error banner title
      expect(find.text('解析发生严重错误 (1 条记录)'), findsOneWidget);
    });
  });

  testWidgets(
      'ImportStagingScreen falls back to first question _import_diagnostics',
      (WidgetTester tester) async {
    final parsed = [
      {
        'type': 0,
        'content': 'Question 1',
        'standard_answer': 'A',
        '_import_diagnostics': ['Fallback warning 1', 'Fallback warning 2'],
      }
    ];

    await tester.runAsync(() async {
      // Pass no warnings or diagnostics parameters, testing the fallback path
      await tester.pumpWidget(createWidgetUnderTest(parsedQuestions: parsed));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('解析有注意事项 (2 条记录)'), findsOneWidget);

      await tester.tap(find.text('查看详情'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Fallback warning 1'), findsOneWidget);
      expect(find.text('Fallback warning 2'), findsOneWidget);

      // Close bottom sheet
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    });
  });
}
