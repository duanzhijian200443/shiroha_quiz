import 'dart:convert';

import '../../domain/question/question_draft_v2.dart';
import 'study_query_dtos.dart';
import 'study_query_ports.dart';
import 'study_query_stem_preview.dart';

/// Stateless safe projection shared by StudyQuery and scoped external reads.
/// Projection supplies no authentication, Scope or permission.
final class StudyQuestionProjection {
  const StudyQuestionProjection();
  static const _preview = StemPreviewNormalizer();
  QuestionSearchItem searchItem(StudyQuestionRead read) {
    return switch (read) {
      TypedStudyQuestionRead(
        :final questionId,
        :final bankName,
        :final draft,
        :final review,
      ) =>
        QuestionSearchItem(
          questionId: questionId,
          bankName: bankName,
          kind: _kindOfDraft(draft.kind),
          stemPreview: _preview.fromRichContent(draft.stem),
          hasAnswer: draft.answer != null,
          hasExplanation: draft.explanation != null,
          due: review.due,
          sourceKind: StudySourceKind.typed,
        ),
      LegacyStudyQuestionRead(
        :final questionId,
        :final bankName,
        :final stemText,
        :final answerText,
        :final explanationText,
        :final legacyType,
        :final review,
      ) =>
        QuestionSearchItem(
          questionId: questionId,
          bankName: bankName,
          kind: _kindOfLegacyType(legacyType),
          stemPreview: _preview.normalizeText(stemText),
          hasAnswer: answerText.trim().isNotEmpty,
          hasExplanation: explanationText?.trim().isNotEmpty ?? false,
          due: review.due,
          sourceKind: StudySourceKind.legacy,
        ),
    };
  }

  QuestionDetail detail(StudyQuestionRead read) {
    return switch (read) {
      TypedStudyQuestionRead(
        :final questionId,
        :final bankName,
        :final draft,
        :final review,
      ) =>
        QuestionDetail(
          questionId: questionId,
          bankName: bankName,
          kind: _kindOfDraft(draft.kind),
          stem: StemPreviewNormalizer.projectNodes(draft.stem),
          options: <StudyOption>[
            for (final option in draft.options)
              StudyOption(
                label: option.label,
                content: StemPreviewNormalizer.projectNodes(option.content),
              ),
          ],
          answer: _projectAnswer(draft.answer, draft.options),
          explanation: draft.explanation == null
              ? null
              : StemPreviewNormalizer.projectNodes(draft.explanation!),
          due: review.due,
          sourceKind: StudySourceKind.typed,
        ),
      LegacyStudyQuestionRead(
        :final questionId,
        :final bankName,
        :final stemText,
        :final optionsText,
        :final answerText,
        :final explanationText,
        :final legacyType,
        :final review,
      ) =>
        QuestionDetail(
          questionId: questionId,
          bankName: bankName,
          kind: _kindOfLegacyType(legacyType),
          stem: <StudyContentNode>[StudyTextNode(stemText)],
          options: _legacyOptions(optionsText),
          answer: answerText.trim().isEmpty
              ? null
              : <StudyContentNode>[StudyTextNode(answerText)],
          explanation: explanationText == null || explanationText.trim().isEmpty
              ? null
              : <StudyContentNode>[StudyTextNode(explanationText)],
          due: review.due,
          sourceKind: StudySourceKind.legacy,
        ),
    };
  }

  List<StudyContentNode>? _projectAnswer(
    QuestionAnswer? answer,
    List<QuestionOption> options,
  ) {
    return switch (answer) {
      null => null,
      ContentAnswer(:final content) =>
        StemPreviewNormalizer.projectNodes(content),
      ChoiceAnswer(:final optionIds) => <StudyContentNode>[
          for (final optionId in optionIds)
            for (final option in options)
              if (option.optionId == optionId) StudyTextNode(option.label),
        ],
    };
  }

  List<StudyOption> _legacyOptions(String optionsText) {
    final Object? decoded;
    try {
      decoded = jsonDecode(optionsText);
    } on FormatException {
      return const <StudyOption>[];
    }
    if (decoded is! List) return const <StudyOption>[];
    return <StudyOption>[
      for (final entry in decoded)
        if (entry is String) _legacyOption(entry),
    ];
  }

  StudyOption _legacyOption(String raw) {
    final separator = raw.indexOf('. ');
    if (separator > 0) {
      return StudyOption(
        label: raw.substring(0, separator),
        content: <StudyContentNode>[
          StudyTextNode(raw.substring(separator + 2)),
        ],
      );
    }
    return StudyOption(
      label: '',
      content: <StudyContentNode>[StudyTextNode(raw)],
    );
  }

  StudyQuestionKind _kindOfDraft(QuestionKind kind) {
    return switch (kind) {
      QuestionKind.singleChoice => StudyQuestionKind.singleChoice,
      QuestionKind.fillBlank => StudyQuestionKind.fillBlank,
      QuestionKind.shortAnswer => StudyQuestionKind.shortAnswer,
    };
  }

  StudyQuestionKind _kindOfLegacyType(int type) {
    return switch (type) {
      0 || 1 => StudyQuestionKind.singleChoice,
      2 => StudyQuestionKind.fillBlank,
      3 => StudyQuestionKind.shortAnswer,
      _ => StudyQuestionKind.unknown,
    };
  }
}
