enum QuestionParseMode {
  all('all'),
  stemOnly('stem_only'),
  answerOnly('answer_only');

  const QuestionParseMode(this.legacyValue);

  final String legacyValue;

  static QuestionParseMode fromLegacyValue(String? value) {
    return switch (value) {
      'stem_only' => QuestionParseMode.stemOnly,
      'answer_only' => QuestionParseMode.answerOnly,
      'all' || null || '' => QuestionParseMode.all,
      _ => QuestionParseMode.all,
    };
  }

  bool get isStemOnly => this == QuestionParseMode.stemOnly;
  bool get isAnswerOnly => this == QuestionParseMode.answerOnly;
}
