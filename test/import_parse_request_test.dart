import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_parse_request.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_field_policy.dart';

void main() {
  group('ImportParseRequest mode', () {
    test('exposes the three supported modes', () {
      expect(
        ImportParseMode.values,
        <ImportParseMode>[
          ImportParseMode.text,
          ImportParseMode.vision,
          ImportParseMode.ocr,
        ],
      );
    });

    test('retains the selected mode without changing current routing semantics',
        () {
      ImportParseRequest requestFor(ImportParseMode mode) => ImportParseRequest(
            filePaths: const <String>['exam.pdf'],
            fileNames: const <String>['exam.pdf'],
            mode: mode,
            maxConcurrency: 3,
            taskId: 'task-1',
          );

      expect(requestFor(ImportParseMode.text).mode, ImportParseMode.text);
      expect(requestFor(ImportParseMode.text).useVisionEngine, isFalse);
      expect(requestFor(ImportParseMode.vision).useVisionEngine, isTrue);
      expect(requestFor(ImportParseMode.ocr).useVisionEngine, isTrue);
    });

    test('uses the safe explanation retention default and preserves overrides',
        () {
      const defaultRequest = ImportParseRequest(
        filePaths: <String>['exam.pdf'],
        fileNames: <String>['exam.pdf'],
        mode: ImportParseMode.vision,
        maxConcurrency: 3,
        taskId: 'task-default-retention',
      );
      const retainedRequest = ImportParseRequest(
        filePaths: <String>['exam.pdf'],
        fileNames: <String>['exam.pdf'],
        mode: ImportParseMode.vision,
        maxConcurrency: 3,
        taskId: 'task-retain-all',
        explanationRetentionMode: ExplanationRetentionMode.allQuestionTypes,
      );

      expect(
        defaultRequest.explanationRetentionMode,
        ExplanationRetentionMode.subjectiveOnly,
      );
      expect(
        retainedRequest.explanationRetentionMode,
        ExplanationRetentionMode.allQuestionTypes,
      );
    });
  });
}
