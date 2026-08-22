import 'dart:convert';

import '../../data/models/persisted_question.dart';
import '../../data/models/question.dart';
import '../../domain/content/content_node.dart';
import '../../domain/content/rich_content.dart';
import '../../domain/content/rich_content_text_projection.dart';
import '../../domain/question/question_draft_v2.dart';
import '../../utils/ai_data_sanitizer.dart';

/// Display-only projection of one persisted question. The UI renders this
/// view and never touches the repository, the database row, or the legacy
/// compatibility projection of a typed row.
enum PersistedQuestionViewKind {
  singleChoice,
  multipleChoice,
  fillBlank,
  shortAnswer,
  unknown,
}

/// One option rendered by the question card. Typed options carry rich
/// content; legacy options carry the safely parsed display text.
final class PersistedQuestionOptionView {
  const PersistedQuestionOptionView({
    required this.label,
    required this.typedContent,
    required this.legacyText,
  });

  final String label;
  final RichContent? typedContent;
  final String legacyText;
}

/// Immutable presentation view used by [QuestionListScreen] and
/// [PersistedQuestionCard]. Raw database maps never enter the UI.
final class PersistedQuestionView {
  const PersistedQuestionView({
    required this.storageId,
    required this.bankName,
    required this.createdAt,
    required this.kind,
    required this.isTyped,
    required this.typedStem,
    required this.legacyStem,
    required this.options,
    required this.typedAnswer,
    required this.legacyAnswer,
    required this.typedExplanation,
    required this.legacyExplanation,
    required this.legacyEditPayload,
    required this.typedDraft,
    required this.searchText,
    this.reviewMetrics,
  });

  final String storageId;
  final String bankName;
  final int createdAt;
  final PersistedQuestionViewKind kind;
  final bool isTyped;

  /// Typed rows always carry the typed stem; legacy rows always carry the
  /// compatibility text. A typed explicit empty stem is preserved as typed
  /// empty and never falls back to the compatibility row.
  final RichContent? typedStem;
  final String legacyStem;

  final List<PersistedQuestionOptionView> options;

  final RichContent? typedAnswer;
  final String legacyAnswer;

  final RichContent? typedExplanation;
  final String legacyExplanation;

  /// Non-null only for legacy rows: a defensive copy of the legacy
  /// [Question.toMap] payload accepted by the old editor.
  final Map<String, dynamic>? legacyEditPayload;

  /// Non-null only for typed rows: the sidecar draft consumed by the typed
  /// editor. Legacy rows always carry null (mirroring [legacyEditPayload]).
  final QuestionDraftV2? typedDraft;

  /// In-memory search text. Never contains raw fallback payloads, source or
  /// asset references, issues, storage ids, bank names, or database metadata.
  final String searchText;

  /// Present only when the underlying read joined `review_states` (the
  /// wrong-book surface); null on the regular bank list.
  final PersistedQuestionReviewMetrics? reviewMetrics;
}

/// Converts persisted union rows into display views at one boundary so the
/// typed/legacy branching never spreads across widgets.
abstract final class PersistedQuestionViewAdapter {
  static PersistedQuestionView fromPersisted(PersistedQuestion question) {
    return switch (question) {
      TypedPersistedQuestion(:final draft) => _fromTyped(question, draft),
      LegacyPersistedQuestion(question: final legacy) =>
        _fromLegacy(question, legacy),
    };
  }

  static PersistedQuestionView _fromTyped(
    TypedPersistedQuestion typed,
    QuestionDraftV2 draft,
  ) {
    return PersistedQuestionView(
      storageId: typed.storageId,
      bankName: typed.bankName,
      createdAt: typed.createdAt,
      kind: _typedKind(draft.kind),
      isTyped: true,
      typedStem: draft.stem,
      legacyStem: '',
      options: List<PersistedQuestionOptionView>.unmodifiable(
        <PersistedQuestionOptionView>[
          for (final option in draft.options)
            PersistedQuestionOptionView(
              label: option.label,
              typedContent: option.content,
              legacyText: '',
            ),
        ],
      ),
      typedAnswer: _typedAnswer(draft),
      legacyAnswer: '',
      typedExplanation: draft.explanation,
      legacyExplanation: '',
      legacyEditPayload: null,
      typedDraft: draft,
      searchText: _typedSearchText(draft),
      reviewMetrics: typed.reviewMetrics,
    );
  }

  static PersistedQuestionView _fromLegacy(
    LegacyPersistedQuestion legacy,
    Question question,
  ) {
    return PersistedQuestionView(
      storageId: legacy.storageId,
      bankName: legacy.bankName,
      createdAt: legacy.createdAt,
      kind: _legacyKind(question.type),
      isTyped: false,
      typedStem: null,
      legacyStem: question.content,
      options: _parseLegacyOptions(question.options),
      typedAnswer: null,
      legacyAnswer: question.answer,
      typedExplanation: null,
      legacyExplanation: question.explanation ?? '',
      legacyEditPayload: Map<String, dynamic>.unmodifiable(question.toMap()),
      typedDraft: null,
      searchText: _legacySearchText(question),
      reviewMetrics: legacy.reviewMetrics,
    );
  }

  static PersistedQuestionViewKind _typedKind(QuestionKind kind) {
    return switch (kind) {
      QuestionKind.singleChoice => PersistedQuestionViewKind.singleChoice,
      QuestionKind.fillBlank => PersistedQuestionViewKind.fillBlank,
      QuestionKind.shortAnswer => PersistedQuestionViewKind.shortAnswer,
    };
  }

  static PersistedQuestionViewKind _legacyKind(int type) {
    return switch (type) {
      0 => PersistedQuestionViewKind.singleChoice,
      1 => PersistedQuestionViewKind.multipleChoice,
      2 => PersistedQuestionViewKind.fillBlank,
      3 => PersistedQuestionViewKind.shortAnswer,
      _ => PersistedQuestionViewKind.unknown,
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

  static String _typedSearchText(QuestionDraftV2 draft) {
    final parts = <String>[
      _projectForSearch(draft.stem),
      for (final option in draft.options) ...<String>[
        option.label,
        _projectForSearch(option.content)
      ],
    ];
    switch (draft.answer) {
      case null:
        break;
      case ContentAnswer(:final content):
        parts.add(_projectForSearch(content));
      case ChoiceAnswer(:final optionIds):
        parts.add(
          optionIds
              .map((optionId) => _optionLabel(optionId, draft.options))
              .join(', '),
        );
    }
    final explanation = draft.explanation;
    if (explanation != null) {
      parts.add(_projectForSearch(explanation));
    }
    return parts.join(' ');
  }

  /// Projects rich content into searchable plain text. Raw fallback nodes
  /// are ignored: rawJson, payload, source, and path data never enter the
  /// search text.
  static String _projectForSearch(RichContent content) {
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

  static final RegExp _legacyOptionPrefixPattern = RegExp(
    r'^(?:\s*(?:[A-D][\.、．]|\([A-D]\)|（[A-D]）)\s*)+',
  );

  /// Parses the legacy options JSON defensively: only JSON lists are
  /// accepted, only String entries are kept (Map/List sub-objects are never
  /// stringified), and any parse failure returns an empty list without
  /// throwing. Labels keep the existing A/B/C... strategy.
  static List<PersistedQuestionOptionView> _parseLegacyOptions(
    String? optionsJson,
  ) {
    if (optionsJson == null || optionsJson.isEmpty) {
      return const <PersistedQuestionOptionView>[];
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(optionsJson);
    } on FormatException {
      return const <PersistedQuestionOptionView>[];
    }
    if (decoded is! List) {
      return const <PersistedQuestionOptionView>[];
    }
    final views = <PersistedQuestionOptionView>[];
    for (var index = 0; index < decoded.length; index++) {
      final value = decoded[index];
      if (value is! String) continue;
      final label = String.fromCharCode(65 + index);
      final trimmed = value.trim();
      final stripped =
          trimmed.replaceFirst(_legacyOptionPrefixPattern, '').trim();
      views.add(
        PersistedQuestionOptionView(
          label: label,
          typedContent: null,
          legacyText: AiDataSanitizer.cleanLatexBeforeDB(
            stripped.isEmpty ? trimmed : stripped,
          ),
        ),
      );
    }
    return List<PersistedQuestionOptionView>.unmodifiable(views);
  }

  static String _legacySearchText(Question question) {
    return <String>[
      question.content,
      for (final option in _parseLegacyOptions(question.options))
        option.legacyText,
      question.answer,
      question.explanation ?? '',
    ].join(' ');
  }
}
