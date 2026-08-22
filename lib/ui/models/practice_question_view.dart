import 'dart:convert';

import '../../data/models/persisted_question.dart';
import '../../data/models/question.dart';
import '../../domain/content/content_node.dart';
import '../../domain/content/rich_content.dart';
import '../../domain/content/rich_content_text_projection.dart';
import '../../domain/question/question_draft_v2.dart';

/// Practice interaction kind projected from the underlying row.
enum PracticeQuestionKind {
  singleChoice,
  multipleChoice,
  fillBlank,
  shortAnswer,
  unknown,
}

/// One selectable option in a practice session. Typed options carry their
/// `optionId` and rich content; legacy options carry the raw stored text that
/// the legacy render path parses exactly as before.
final class PracticeOptionView {
  const PracticeOptionView({
    required this.label,
    this.optionId,
    this.typedContent,
    this.legacyRaw,
  });

  /// Typed rows: the draft option label. Legacy rows: the A/B/C... letter.
  final String label;

  /// Non-null only for typed rows; interaction never derives it from legacy
  /// letter text.
  final String? optionId;
  final RichContent? typedContent;
  final String? legacyRaw;
}

/// Immutable read-only projection that carries the interaction semantics of
/// one practice question. Typed rows are always sourced from the sidecar
/// draft (stem/options/answer/explanation); legacy rows keep their legacy
/// fields untouched.
final class PracticeQuestionView {
  const PracticeQuestionView({
    required this.source,
    required this.isTyped,
    required this.kind,
    required this.storageId,
    required this.isPreview,
    required this.bankName,
    required this.typedStem,
    required this.legacyStem,
    required this.displayOptions,
    required this.answerOptionIds,
    required this.contentAnswer,
    required this.typedAnswer,
    required this.legacyAnswer,
    required this.legacyRawExplanation,
    required this.legacyExplanation,
    required this.typedExplanation,
    required this.legacyQuestion,
    required this.stemText,
    required this.answerText,
  });

  /// The session source row. Null only for in-memory preview questions.
  final PersistedQuestion? source;
  final bool isTyped;
  final PracticeQuestionKind kind;
  final String storageId;
  final bool isPreview;
  final String bankName;

  final RichContent? typedStem;
  final String legacyStem;
  final List<PracticeOptionView> displayOptions;

  /// Typed `ChoiceAnswer` option identities (structural mapping).
  final List<String> answerOptionIds;
  final RichContent? contentAnswer;

  /// Typed answer for display: `ContentAnswer` content or `ChoiceAnswer`
  /// option labels. Null when the typed answer is explicitly empty.
  final RichContent? typedAnswer;
  final String legacyAnswer;
  final String? legacyRawExplanation;
  final String? legacyExplanation;
  final RichContent? typedExplanation;

  /// Non-null for legacy rows and preview questions; null for typed rows.
  final Question? legacyQuestion;

  /// Safe plain-text projections used only by AI interactions (judging and
  /// variant generation). RawFallback payloads never enter these strings.
  final String stemText;
  final String answerText;

  /// Question for the legacy LLM service. Legacy rows pass their own
  /// [Question]; typed rows are projected from the sidecar draft and never
  /// read the V1 compatibility row.
  Question? get interactionQuestion {
    final legacy = legacyQuestion;
    if (legacy != null) return legacy;
    return Question(
      id: storageId,
      type: _legacyTypeCode(kind),
      content: stemText,
      options: jsonEncode(<String>[
        for (final option in displayOptions)
          '${option.label}. '
              '${option.typedContent == null ? '' : _projectForText(option.typedContent!)}',
      ]),
      answer: answerText,
      createdAt: 0,
      bankName: bankName,
    );
  }
}

/// Converts persisted union rows (and in-memory preview questions) into the
/// practice projection at one boundary.
abstract final class PracticeQuestionViewAdapter {
  static PracticeQuestionView fromPersisted(PersistedQuestion question) {
    return switch (question) {
      TypedPersistedQuestion(:final draft) => _fromTyped(question, draft),
      LegacyPersistedQuestion() => _fromLegacyQuestion(
          question: question.question,
          source: question,
          storageId: question.storageId,
        ),
    };
  }

  static PracticeQuestionView fromLegacyQuestion(Question question) {
    final storageId =
        question.id ?? 'preview_${DateTime.now().millisecondsSinceEpoch}';
    return _fromLegacyQuestion(
      question: question,
      source: null,
      storageId: storageId,
    );
  }

  static PracticeQuestionView _fromTyped(
    TypedPersistedQuestion typed,
    QuestionDraftV2 draft,
  ) {
    return PracticeQuestionView(
      source: typed,
      isTyped: true,
      kind: _typedKind(draft.kind),
      storageId: typed.storageId,
      isPreview: typed.storageId.startsWith('preview_'),
      bankName: typed.bankName,
      typedStem: draft.stem,
      legacyStem: '',
      displayOptions: List<PracticeOptionView>.unmodifiable(
        <PracticeOptionView>[
          for (final option in draft.options)
            PracticeOptionView(
              label: option.label,
              optionId: option.optionId,
              typedContent: option.content,
            ),
        ],
      ),
      answerOptionIds: switch (draft.answer) {
        ChoiceAnswer(:final optionIds) => List<String>.unmodifiable(optionIds),
        _ => const <String>[],
      },
      contentAnswer: switch (draft.answer) {
        ContentAnswer(:final content) => content,
        _ => null,
      },
      typedAnswer: _typedAnswer(draft),
      legacyAnswer: '',
      legacyRawExplanation: null,
      legacyExplanation: null,
      typedExplanation: draft.explanation,
      legacyQuestion: null,
      stemText: _projectForText(draft.stem),
      answerText: _typedAnswerText(draft),
    );
  }

  static PracticeQuestionView _fromLegacyQuestion({
    required Question question,
    required PersistedQuestion? source,
    required String storageId,
  }) {
    return PracticeQuestionView(
      source: source,
      isTyped: false,
      kind: _legacyKind(question.type),
      storageId: storageId,
      isPreview: storageId.startsWith('preview_'),
      bankName: question.bankName,
      typedStem: null,
      legacyStem: question.content,
      displayOptions: _parseLegacyOptions(question.options),
      answerOptionIds: const <String>[],
      contentAnswer: null,
      typedAnswer: null,
      legacyAnswer: question.answer,
      legacyRawExplanation: question.rawExplanation,
      legacyExplanation: question.explanation,
      typedExplanation: null,
      legacyQuestion: question,
      stemText: question.content,
      answerText: question.answer,
    );
  }

  static PracticeQuestionKind _typedKind(QuestionKind kind) {
    return switch (kind) {
      QuestionKind.singleChoice => PracticeQuestionKind.singleChoice,
      QuestionKind.fillBlank => PracticeQuestionKind.fillBlank,
      QuestionKind.shortAnswer => PracticeQuestionKind.shortAnswer,
    };
  }

  static PracticeQuestionKind _legacyKind(int type) {
    return switch (type) {
      0 => PracticeQuestionKind.singleChoice,
      1 => PracticeQuestionKind.multipleChoice,
      2 => PracticeQuestionKind.fillBlank,
      3 => PracticeQuestionKind.shortAnswer,
      _ => PracticeQuestionKind.unknown,
    };
  }

  /// Defensive legacy option parsing with exactly the same semantics as the
  /// pre-migration practice page: JSON list entries are kept, a double-encoded
  /// string is decoded once, and any other shape degrades to the raw string.
  static List<PracticeOptionView> _parseLegacyOptions(String? raw) {
    if (raw == null || raw.isEmpty) return const <PracticeOptionView>[];
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return <PracticeOptionView>[
        PracticeOptionView(label: 'A', legacyRaw: raw),
      ];
    }
    if (decoded is String) {
      final firstLevel = decoded;
      try {
        decoded = jsonDecode(firstLevel);
      } on FormatException {
        return <PracticeOptionView>[
          PracticeOptionView(label: 'A', legacyRaw: firstLevel),
        ];
      }
    }
    if (decoded is List) {
      return List<PracticeOptionView>.unmodifiable(
        <PracticeOptionView>[
          for (var index = 0; index < decoded.length; index++)
            PracticeOptionView(
              label: String.fromCharCode(65 + index),
              legacyRaw: decoded[index].toString(),
            ),
        ],
      );
    }
    return <PracticeOptionView>[
      PracticeOptionView(label: 'A', legacyRaw: raw),
    ];
  }

  static String _typedAnswerText(QuestionDraftV2 draft) {
    return switch (draft.answer) {
      null => '',
      ContentAnswer(:final content) => _projectForText(content),
      ChoiceAnswer(:final optionIds) => optionIds
          .map((optionId) => _optionLabel(optionId, draft.options))
          .join(', '),
    };
  }

  static RichContent? _typedAnswer(QuestionDraftV2 draft) {
    return switch (draft.answer) {
      null => null,
      ContentAnswer(:final content) => content,
      ChoiceAnswer(:final optionIds) => RichContent(
          nodes: <ContentNode>[
            TextNode(
              optionIds
                  .map((optionId) => _optionLabel(optionId, draft.options))
                  .join(', '),
            ),
          ],
        ),
    };
  }

  static String _optionLabel(String optionId, List<QuestionOption> options) {
    for (final option in options) {
      if (option.optionId == optionId) return option.label;
    }
    return optionId;
  }
}

/// Projects rich content into plain text. Raw fallback nodes are ignored:
/// rawJson, payload, source, and path data never enter the text.
String _projectForText(RichContent content) {
  final parts = <String>[];
  for (final node in content.nodes) {
    switch (node) {
      case TextNode(:final text):
        parts.add(text);
      case InlineMathNode(:final latex):
        parts.add(latex);
      case BlockMathNode(:final latex):
        parts.add(latex);
      case ImageNode() || TableNode():
        parts.add(
          const RichContentTextProjection().project(
            RichContent(nodes: <ContentNode>[node]),
          ),
        );
      case RawFallbackNode():
        break;
    }
  }
  return parts.join(' ');
}

int _legacyTypeCode(PracticeQuestionKind kind) {
  return switch (kind) {
    PracticeQuestionKind.singleChoice => 0,
    PracticeQuestionKind.multipleChoice => 1,
    PracticeQuestionKind.fillBlank => 2,
    PracticeQuestionKind.shortAnswer => 3,
    PracticeQuestionKind.unknown => 0,
  };
}
