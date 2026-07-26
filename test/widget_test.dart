// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

// import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';
import 'package:shiroha_quiz/main.dart';
import 'package:shiroha_quiz/services/ai_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_pipeline_service.dart';
import 'package:shiroha_quiz/services/task_manager.dart';
import 'package:shiroha_quiz/ui/pages/main_screen.dart';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    // Initialize sqflite ffi for desktop/testing
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('App starts and shows splash screen',
      (WidgetTester tester) async {
    final engineRepository =
        AiEngineRepository(store: DatabaseHelper.instance);
    final taskManager = TaskManager.forTesting();
    final aiService = AiService(
      engineRepository: engineRepository,
      taskManager: taskManager,
    );
    final importPipelineService = ImportPipelineService(
      aiService: aiService,
      engineRepository: engineRepository,
      taskManager: taskManager,
    );

    // Build our app and trigger a frame.
    await tester.pumpWidget(ShirohaQuizApp(
      engineRepository: engineRepository,
      aiService: aiService,
      importPipelineService: importPipelineService,
    ));

    // Verify that MainScreen is shown initially.
    expect(find.byType(MainScreen), findsOneWidget);
  });
}
