import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/models/question_parse_mode.dart';
import 'package:shiroha_quiz/services/document_parse_router.dart';

void main() {
  group('DocumentParseRouter', () {
    const router = DocumentParseRouter();

    test('routes inline answers with duplicated tail answers through trim path',
        () {
      final plan = router.buildPlan(
        '1. 题干 答案：A\n\n正文解析\n\n参考答案\n1. A',
        isMarkdown: false,
      );

      expect(plan.route, DocumentParseRoute.trimTailAnswers);
      expect(plan.segments, hasLength(1));
      expect(plan.segments.single.parseMode, QuestionParseMode.all);
      expect(plan.segments.single.batches.join(), isNot(contains('参考答案')));
    });

    test('routes separated stems and tail answers into two parse modes', () {
      final plan = router.buildPlan(
        '1. 题干一\n2. 题干二\n\n参考答案\n1. A\n2. B',
        isMarkdown: false,
      );

      expect(plan.route, DocumentParseRoute.splitStemAndAnswer);
      expect(plan.segments, hasLength(2));
      expect(plan.segments[0].parseMode, QuestionParseMode.stemOnly);
      expect(plan.segments[1].parseMode, QuestionParseMode.answerOnly);
    });
  });
}
