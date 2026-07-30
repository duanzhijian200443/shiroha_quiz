import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/import/import_issue.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';

void main() {
  group('ImportIssue valid construction', () {
    test('supports every severity and safe domain field', () {
      for (final severity in ImportIssueSeverity.values) {
        final issue = ImportIssue(
          code: 'future_layout_conflict',
          severity: severity,
        );
        expect(issue.severity, severity);
      }

      for (final field in ImportIssueField.values) {
        final issue = ImportIssue(
          code: 'field_requires_review',
          severity: ImportIssueSeverity.warning,
          field: field,
        );
        expect(issue.field, field);
      }
    });

    test('accepts an unknown future code and optional source reference', () {
      final sourceRef = SourceRef.at(
        sourceId: 'source_001',
        point: SourcePoint.block(
          pageNumber: 1,
          blockId: 'block_001',
          readingOrder: 0,
        ),
      );
      final issue = ImportIssue(
        code: 'future_layout_conflict',
        severity: ImportIssueSeverity.info,
        field: ImportIssueField.source,
        sourceRef: sourceRef,
      );

      expect(issue.code, 'future_layout_conflict');
      expect(issue.sourceRef, sourceRef);
    });

    test('uses stable value equality and hash codes', () {
      final first = ImportIssue(
        code: 'missing_answer',
        severity: ImportIssueSeverity.error,
        field: ImportIssueField.answer,
      );
      final equal = ImportIssue(
        code: 'missing_answer',
        severity: ImportIssueSeverity.error,
        field: ImportIssueField.answer,
      );
      final different = ImportIssue(
        code: 'missing_answer',
        severity: ImportIssueSeverity.warning,
        field: ImportIssueField.answer,
      );

      expect(equal, first);
      expect(equal.hashCode, first.hashCode);
      expect(<ImportIssue>{first}, contains(equal));
      expect(different, isNot(first));
    });
  });

  group('ImportIssue invalid construction', () {
    test('rejects unsafe or non-canonical issue codes', () {
      final invalidCodes = <String>[
        '',
        ' ',
        'MissingAnswer',
        'missing-answer',
        '_missing_answer',
        'missing_answer_',
        'missing__answer',
        'missing answer',
        'a' * 65,
      ];

      for (final code in invalidCodes) {
        expect(
          () => ImportIssue(
            code: code,
            severity: ImportIssueSeverity.error,
          ),
          throwsFormatException,
        );
      }
    });
  });
}
