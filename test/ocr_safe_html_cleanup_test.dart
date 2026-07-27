import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_safe_html_cleanup.dart';

import '../tool/import_acceptance.dart';

void main() {
  group('stripSafeHtmlWrappers', () {
    test('strips a div wrapper and preserves its text', () {
      final result = stripSafeHtmlWrappers('<div>正文</div>');

      expect(result.text, '正文');
      expect(result.diagnostics, isEmpty);
    });

    test('strips nested div and span wrappers', () {
      final result = stripSafeHtmlWrappers('<div><span>正文</span></div>');

      expect(result.text, '正文');
      expect(result.diagnostics, isEmpty);
    });

    test('preserves paragraph boundaries as newlines', () {
      final result = stripSafeHtmlWrappers('<p>第一行</p><p>第二行</p>');

      expect(result.text, '第一行\n第二行');
    });

    test('converts br variants to newlines', () {
      final result = stripSafeHtmlWrappers('第一行<br>第二行<br/>第三行<br />第四行');

      expect(result.text, '第一行\n第二行\n第三行\n第四行');
    });

    test('preserves formulas inside safe wrappers and decodes entities', () {
      final result = stripSafeHtmlWrappers(
        r'<div>\(a &lt; b &amp; c &gt; d\)</div>',
      );

      expect(result.text, r'\(a < b & c > d\)');
    });

    test('does not treat ordinary comparison signs as HTML', () {
      const original = '当 a < b 且 c > d 时保持原式。';

      final result = stripSafeHtmlWrappers(original);

      expect(result.text, original);
      expect(result.diagnostics, isEmpty);
    });

    test('removes dangerous containers and records a fixed diagnostic', () {
      final result = stripSafeHtmlWrappers(
        '安全正文'
        '<script>dangerousScript()</script>'
        '<style>.hidden { display: none; }</style>'
        '<iframe>embedded content</iframe>'
        '结尾',
      );

      expect(result.text, '安全正文结尾');
      expect(result.text, isNot(contains('dangerousScript')));
      expect(result.text, isNot(contains('display')));
      expect(result.text, isNot(contains('iframe')));
      expect(result.diagnostics, contains('unsafe_html_content_removed'));
    });

    test('preserves unsupported tags and records a fixed diagnostic', () {
      const original = '<custom-tag>正文</custom-tag>';

      final result = stripSafeHtmlWrappers(original);

      expect(result.text, original);
      expect(
        result.diagnostics,
        contains('unsupported_html_tag_preserved'),
      );
    });

    test('cleanup prevents raw_html_tag from the acceptance quality gate', () {
      final cleaned = stripSafeHtmlWrappers('<div><span>正文</span></div>');
      const testCase = ImportAcceptanceCase(
        schemaVersion: 1,
        caseId: 'html_cleanup',
        pdf: 'synthetic.pdf',
        expectedQuestionCount: 1,
        expectedNumbers: [1],
        allowDuplicateNumbers: false,
      );

      final quality = runAcceptanceQualityChecks(
        questions: [
          {
            'question_number': 1,
            'type': 3,
            'content': cleaned.text,
            'options': <String>[],
            'standard_answer': 'answer',
            'explanation': '',
          },
        ],
        testCase: testCase,
      );

      expect(
        quality.questionReports.single.issues
            .any((issue) => issue.code == 'raw_html_tag'),
        isFalse,
      );
    });

    test('leaves content without HTML or entities unchanged', () {
      const original = r'普通正文与公式 \(x^2 + y^2 = 1\)。';

      final result = stripSafeHtmlWrappers(original);

      expect(result.text, original);
      expect(result.diagnostics, isEmpty);
    });
  });
}
