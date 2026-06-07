import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/services/task_manager.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('ImportTask Diagnostics Serialization & TaskManager Tests', () {
    test('toMap and fromMap preserves warnings and diagnostics', () {
      final task = ImportTask(
        id: 'test_task_1',
        title: 'Test Document',
        warnings: ['Warning 1', 'Warning 2'],
        diagnostics: {
          'pdf_render': {'status': 'crash', 'error': 'Failed'},
          'vision_batch': {'failedBatchCount': 1},
        },
      );

      final map = task.toMap();
      expect(map['warnings'], isNotNull);
      expect(map['diagnostics'], isNotNull);

      final decodedTask = ImportTask.fromMap(map);
      expect(decodedTask.id, 'test_task_1');
      expect(decodedTask.title, 'Test Document');
      expect(decodedTask.warnings, containsAll(['Warning 1', 'Warning 2']));
      expect(decodedTask.diagnostics, isNotNull);
      expect(decodedTask.diagnostics!['pdf_render']['status'], 'crash');
      expect(decodedTask.diagnostics!['vision_batch']['failedBatchCount'], 1);
    });

    test('fromMap handles null warnings and diagnostics gracefully', () {
      final task = ImportTask(
        id: 'test_task_2',
        title: 'Test Document 2',
      );

      final map = task.toMap();
      expect(map['warnings'], isNull);
      expect(map['diagnostics'], isNull);

      final decodedTask = ImportTask.fromMap(map);
      expect(decodedTask.warnings, isNull);
      expect(decodedTask.diagnostics, isNull);
    });

    test('fromMap handles malformed warnings and diagnostics without crashing',
        () {
      final malformedMap = {
        'id': 'test_task_3',
        'title': 'Test Document 3',
        'status': 0,
        'progress_text': 'running',
        'percent': 0.5,
        'created_at': 12345678,
        'warnings': '{invalid_json}',
        'diagnostics': '[1, 2, 3]', // Expected Map, got List
      };

      final decodedTask = ImportTask.fromMap(malformedMap);
      expect(decodedTask.id, 'test_task_3');
      expect(decodedTask.warnings, isNull);
      expect(decodedTask.diagnostics, isNull);
    });

    test('TaskManager attachDiagnostics updates task successfully', () {
      final taskManager = TaskManager.instance;
      final task = ImportTask(
        id: 'test_task_4',
        title: 'Test Document 4',
      );
      taskManager.addTask(task);

      taskManager.attachDiagnostics(
        'test_task_4',
        warnings: ['Attached Warning'],
        diagnostics: {'some': 'diagnostic'},
      );

      final updated =
          taskManager.tasks.firstWhere((t) => t.id == 'test_task_4');
      expect(updated.warnings, contains('Attached Warning'));
      expect(updated.diagnostics, isNotNull);
      expect(updated.diagnostics!['some'], 'diagnostic');

      // Clean up task so it doesn't pollute database
      taskManager.deleteTask('test_task_4');
    });
  });
}
