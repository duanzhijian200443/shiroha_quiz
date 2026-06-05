import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/models/question_parse_mode.dart';

void main() {
  test('QuestionParseMode preserves legacy parse mode compatibility', () {
    expect(QuestionParseMode.fromLegacyValue('all'), QuestionParseMode.all);
    expect(QuestionParseMode.fromLegacyValue('stem_only'),
        QuestionParseMode.stemOnly);
    expect(QuestionParseMode.fromLegacyValue('answer_only'),
        QuestionParseMode.answerOnly);
    expect(
        QuestionParseMode.fromLegacyValue('bad_value'), QuestionParseMode.all);
    expect(QuestionParseMode.fromLegacyValue(null), QuestionParseMode.all);
    expect(QuestionParseMode.fromLegacyValue(''), QuestionParseMode.all);
  });
}
