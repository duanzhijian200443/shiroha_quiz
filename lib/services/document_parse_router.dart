import '../data/models/question_parse_mode.dart';
import 'document_chunker.dart';
import 'document_profiler.dart';

enum DocumentParseRoute {
  trimTailAnswers,
  splitStemAndAnswer,
  stemOnly,
  inlineAnswers,
}

class DocumentParseSegment {
  const DocumentParseSegment({
    required this.batches,
    required this.parseMode,
  });

  final List<String> batches;
  final QuestionParseMode parseMode;
}

class DocumentParsePlan {
  const DocumentParsePlan({
    required this.profile,
    required this.route,
    required this.segments,
  });

  final DocProfile profile;
  final DocumentParseRoute route;
  final List<DocumentParseSegment> segments;

  String get logMessage {
    return switch (route) {
      DocumentParseRoute.trimTailAnswers =>
        '✂️ [路径 A] 检测到尾部冗余答案块，执行安全物理裁剪 (Offset: ${profile.tailAnswerOffset})...',
      DocumentParseRoute.splitStemAndAnswer =>
        '🧭 [路径 B] 检测到首尾分离结构，实施物理剪切提取...',
      DocumentParseRoute.stemOnly => '🧭 [路径 D] 全文无答案，将生成残缺题干等待用户补填...',
      DocumentParseRoute.inlineAnswers => '🧭 [路径 C] 标准行内解析结构，直接提取...',
    };
  }
}

class DocumentParseRouter {
  const DocumentParseRouter({
    this.chunker = const DocumentChunker(),
  });

  final DocumentChunker chunker;

  DocumentParsePlan buildPlan(
    String rawText, {
    required bool isMarkdown,
  }) {
    final profile = scanDocumentStructure(rawText);

    if (profile.hasInlineAnswers &&
        profile.hasTailAnswerBlock &&
        profile.tailAnswerOffset > 0) {
      final processedText = _safeSubstring(
        rawText,
        0,
        profile.tailAnswerOffset,
      );
      return DocumentParsePlan(
        profile: profile,
        route: DocumentParseRoute.trimTailAnswers,
        segments: [
          DocumentParseSegment(
            batches: chunker.split(processedText, isMarkdown: isMarkdown),
            parseMode: QuestionParseMode.all,
          ),
        ],
      );
    }

    if (!profile.hasInlineAnswers && profile.hasTailAnswerBlock) {
      final offset = profile.tailAnswerOffset.clamp(0, rawText.length);
      final stemText = rawText.substring(0, offset);
      final answerText = rawText.substring(offset);
      return DocumentParsePlan(
        profile: profile,
        route: DocumentParseRoute.splitStemAndAnswer,
        segments: [
          DocumentParseSegment(
            batches: chunker.split(stemText, isMarkdown: isMarkdown),
            parseMode: QuestionParseMode.stemOnly,
          ),
          DocumentParseSegment(
            batches: chunker.split(answerText, isMarkdown: isMarkdown),
            parseMode: QuestionParseMode.answerOnly,
          ),
        ],
      );
    }

    if (!profile.hasInlineAnswers && !profile.hasTailAnswerBlock) {
      return DocumentParsePlan(
        profile: profile,
        route: DocumentParseRoute.stemOnly,
        segments: [
          DocumentParseSegment(
            batches: chunker.split(rawText, isMarkdown: isMarkdown),
            parseMode: QuestionParseMode.stemOnly,
          ),
        ],
      );
    }

    return DocumentParsePlan(
      profile: profile,
      route: DocumentParseRoute.inlineAnswers,
      segments: [
        DocumentParseSegment(
          batches: chunker.split(rawText, isMarkdown: isMarkdown),
          parseMode: QuestionParseMode.all,
        ),
      ],
    );
  }

  String _safeSubstring(String text, int start, int end) {
    if (start < 0 || end < start || start > text.length) {
      return text;
    }
    final boundedEnd = end > text.length ? text.length : end;
    return text.substring(start, boundedEnd);
  }
}
