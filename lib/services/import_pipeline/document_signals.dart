class DocumentSignals {
  final int questionMarkerCount;
  final int answerMarkerCount;
  final int imageCount;
  final int tableCount;
  final int formulaLikeCount;
  final bool hasTailAnswerBlock;
  final bool hasInlineAnswers;

  const DocumentSignals({
    this.questionMarkerCount = 0,
    this.answerMarkerCount = 0,
    this.imageCount = 0,
    this.tableCount = 0,
    this.formulaLikeCount = 0,
    this.hasTailAnswerBlock = false,
    this.hasInlineAnswers = false,
  });

  Map<String, dynamic> toMap() {
    return {
      'questionMarkerCount': questionMarkerCount,
      'answerMarkerCount': answerMarkerCount,
      'imageCount': imageCount,
      'tableCount': tableCount,
      'formulaLikeCount': formulaLikeCount,
      'hasTailAnswerBlock': hasTailAnswerBlock,
      'hasInlineAnswers': hasInlineAnswers,
    };
  }

  DocumentSignals operator +(DocumentSignals other) {
    return DocumentSignals(
      questionMarkerCount: questionMarkerCount + other.questionMarkerCount,
      answerMarkerCount: answerMarkerCount + other.answerMarkerCount,
      imageCount: imageCount + other.imageCount,
      tableCount: tableCount + other.tableCount,
      formulaLikeCount: formulaLikeCount + other.formulaLikeCount,
      hasTailAnswerBlock: hasTailAnswerBlock || other.hasTailAnswerBlock,
      hasInlineAnswers: hasInlineAnswers || other.hasInlineAnswers,
    );
  }
}
