import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_parse_request.dart';

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
  });
}
