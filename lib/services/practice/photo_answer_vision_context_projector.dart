import 'dart:convert';

import '../../application/practice/photo_answer_judgement.dart';
import '../../domain/content/content_node.dart';
import '../../domain/content/rich_content.dart';

/// Provider-local structured context. Asset identities never enter the prompt.
final class PhotoAnswerVisionContext {
  PhotoAnswerVisionContext(this.question, this.standardAnswer, this.images);
  final String question;
  final String standardAnswer;
  final List<PhotoAnswerContextImage> images;

  String get manifest => [
        for (var i = 0; i < images.length; i++) '${i + 1} = ${images[i].role}',
        '${images.length + 1} = student_answer',
      ].join('\n');
}

final class PhotoAnswerContextImage {
  const PhotoAnswerContextImage(this.role, this.node);
  final String role;
  final ImageNode node;
}

/// Pure structural projection; no repository, filesystem or provider access.
final class PhotoAnswerVisionContextProjector {
  const PhotoAnswerVisionContextProjector();

  PhotoAnswerVisionContext project(PhotoAnswerJudgementRequest request) {
    final images = <PhotoAnswerContextImage>[];
    String projectContent(RichContent content, String role, int limit) {
      var imageCount = 0;
      var hasContent = false;
      var textScalars = 0;
      var nodeCount = 0;
      List<Map<String, Object?>> visit(RichContent value) {
        return [
          for (final node in value.nodes)
            (() {
              if (++nodeCount > 4096) {
                throw PhotoAnswerJudgementFailure.invalidInput;
              }
              String checkedText(String value) {
                textScalars += value.runes.length;
                if (textScalars > limit) {
                  throw PhotoAnswerJudgementFailure.invalidInput;
                }
                hasContent |= value.trim().isNotEmpty;
                return value;
              }

              return switch (node) {
                TextNode(:final text) => {
                    'type': 'text',
                    'text': checkedText(text)
                  },
                InlineMathNode(:final latex) => {
                    'type': 'inline_math',
                    'latex': checkedText(latex)
                  },
                BlockMathNode(:final latex) => {
                    'type': 'block_math',
                    'latex': checkedText(latex)
                  },
                ImageNode() => (() {
                    hasContent = true;
                    final name = '${role}_image_${++imageCount}';
                    images.add(PhotoAnswerContextImage(name, node));
                    return <String, Object?>{
                      'type': 'image',
                      'asset': name,
                      if (node.alternativeText != null)
                        'alt': visit(node.alternativeText!),
                    };
                  })(),
                TableNode(:final structure) => {
                    'type': 'table',
                    'rows': [
                      for (final row in structure.rows)
                        {
                          'cells': [
                            for (final cell in row.cells)
                              {
                                'rowSpan': cell.rowSpan,
                                'columnSpan': cell.columnSpan,
                                'content': visit(cell.content),
                              }
                          ],
                        }
                    ],
                  },
                RawFallbackNode() =>
                  throw PhotoAnswerJudgementFailure.contextUnsupported,
              };
            })(),
        ];
      }

      final nodes = visit(content);
      if (!hasContent) throw PhotoAnswerJudgementFailure.invalidInput;
      return jsonEncode(nodes);
    }

    final question = projectContent(request.question, 'question', 40000);
    final answer = projectContent(request.standardAnswer, 'answer', 20000);
    return PhotoAnswerVisionContext(
        question, answer, List.unmodifiable(images));
  }
}
