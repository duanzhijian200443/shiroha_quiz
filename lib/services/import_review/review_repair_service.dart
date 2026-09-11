import 'dart:async';
import 'dart:convert';

import '../../application/import_review/typed_review_snapshot.dart';
import '../../core/observability/app_logger.dart';
import '../../data/models/ai_engine_profile.dart';
import '../../data/models/import_question_validation.dart';
import '../../data/models/question_draft.dart';
import '../../data/repositories/ai_engine_repository.dart';
import '../../domain/question/question_draft_v2.dart';
import '../import_pipeline/final_question_latex_audit.dart';
import '../import_pipeline/latex_sanity_checker.dart';
import '../llm_api_client.dart';
import '../llm_providers/llm_provider_registry.dart';
import 'import_review_analyzer.dart';
import 'import_review_item.dart';
import 'import_review_metadata.dart';
import 'review_legacy_field_content.dart';
import 'review_repair_edit.dart';
import 'review_repair_policy.dart';

/// The provider-neutral outcome of one review repair attempt.
///
/// The UI switches on this value; it never parses exception text.
/// `proposalReady` is the only outcome that carries a proposal.
enum ReviewRepairOutcome {
  proposalReady,
  notEligible,
  noActiveEngine,
  providerFailure,
  invalidJson,
  questionIdentityChanged,
  unexpectedFieldChange,
  unsupportedOptionChange,
  emptyResult,
  structuralInvalid,
  latexStillInvalid,
  unsupportedTargetField,
  staleInput,
}

enum _ReviewRepairResponseClassification {
  validContent,
  jsonDecodeFailed,
  nonObject,
  extraKeys,
  parseFailure,
}

extension on _ReviewRepairResponseClassification {
  String get wireName => switch (this) {
        _ReviewRepairResponseClassification.validContent =>
          'repair_content_valid',
        _ReviewRepairResponseClassification.jsonDecodeFailed =>
          'repair_json_decode_failed',
        _ReviewRepairResponseClassification.nonObject => 'repair_non_object',
        _ReviewRepairResponseClassification.extraKeys => 'repair_extra_keys',
        _ReviewRepairResponseClassification.parseFailure =>
          'repair_parse_failure',
      };
}

final class _ReviewRepairResponseInspection {
  const _ReviewRepairResponseInspection({
    required this.decoded,
    required this.jsonDecodeSucceeded,
    required this.decodedTopLevelType,
    required this.extraKeyCount,
    required this.missingKeyCount,
    required this.classification,
  });

  final Map<String, dynamic>? decoded;
  final bool jsonDecodeSucceeded;
  final String decodedTopLevelType;
  final int extraKeyCount;
  final int missingKeyCount;
  final _ReviewRepairResponseClassification classification;

  bool get isValid =>
      classification == _ReviewRepairResponseClassification.validContent;

  Map<String, Object?> get diagnosticData => <String, Object?>{
        'repairContentJsonDecodeSucceeded': jsonDecodeSucceeded,
        'decodedTopLevelType': decodedTopLevelType,
        'contractExtraKeyCount': extraKeyCount,
        'contractMissingKeyCount': missingKeyCount,
        'failureClassification': classification.wireName,
      };
}

/// One repair request captured at user click time.
///
/// It is the staleness anchor: [inputDraft] is exactly what the model saw and
/// [expectedRevision] is the review draft CAS revision at that moment.
final class ReviewRepairRequest {
  ReviewRepairRequest({
    required this.target,
    required this.reviewItemId,
    required QuestionDraft inputDraft,
    required this.expectedRevision,
  }) : inputDraft = freezeReviewDraft(inputDraft);

  final ReviewRepairTarget target;
  final String reviewItemId;
  final QuestionDraft inputDraft;
  final int? expectedRevision;

  ReviewRepairRequest withExpectedRevision(int? revision) {
    return ReviewRepairRequest(
      target: target,
      reviewItemId: reviewItemId,
      inputDraft: inputDraft,
      expectedRevision: revision,
    );
  }
}

/// Local validation outcome of a generated proposal.
final class ReviewRepairValidation {
  const ReviewRepairValidation({
    required this.structuralValid,
    required this.latexValid,
    required this.fieldsInScope,
    this.remainingDiagnostics = const <String>[],
  });

  final bool structuralValid;
  final bool latexValid;
  final bool fieldsInScope;

  /// Safe, fixed diagnostic codes that remain after the repair, for example a
  /// LaTeX problem in a field the repair was not allowed to touch.
  final List<String> remainingDiagnostics;

  bool get isApplicable => structuralValid && latexValid && fieldsInScope;
}

/// A validated, not-yet-applied repair proposal.
///
/// Building a proposal never mutates a review item: it carries the exact input
/// the model saw, the canonical proposed draft, the changed fields and the
/// validation outcome.
final class ReviewRepairProposal {
  ReviewRepairProposal({
    required this.request,
    required QuestionDraft proposedDraft,
    required List<ReviewRepairField> changedFields,
    required this.validation,
  })  : proposedDraft = freezeReviewDraft(proposedDraft),
        changedFields = List<ReviewRepairField>.unmodifiable(changedFields);

  final ReviewRepairRequest request;
  final QuestionDraft proposedDraft;
  final List<ReviewRepairField> changedFields;
  final ReviewRepairValidation validation;

  /// The review question as it was when the proposal was generated.
  QuestionDraft get originalDraft => request.inputDraft;

  /// The question number the repair was generated for.
  int get questionNumber => request.target.questionNumber;

  /// Whether the proposal may be applied. A generated proposal is only handed
  /// to the UI when this is `true`.
  bool get applicable => validation.isApplicable && changedFields.isNotEmpty;

  /// Whether [current] no longer matches the captured input.
  ///
  /// A stale proposal must never overwrite newer review state.
  bool isStaleFor(QuestionDraft current) {
    final input = request.inputDraft;
    return current.type != input.type ||
        current.content != input.content ||
        current.standardAnswer != input.standardAnswer ||
        current.explanation != input.explanation ||
        !_sameList(current.options, input.options);
  }
}

/// Explicit result of a repair attempt.
final class ReviewRepairResult {
  const ReviewRepairResult.ready(ReviewRepairProposal this.proposal)
      : outcome = ReviewRepairOutcome.proposalReady,
        diagnostics = const <String>[];

  const ReviewRepairResult.rejected(
    this.outcome, {
    this.diagnostics = const <String>[],
  }) : proposal = null;

  final ReviewRepairOutcome outcome;
  final ReviewRepairProposal? proposal;

  /// Safe fixed diagnostic codes; never content, provider payloads or paths.
  final List<String> diagnostics;

  bool get hasProposal => proposal != null;
}

/// Reusable single-question review repair primitive.
///
/// The staging UI (and a future batch action) calls this one method per
/// eligible item; it never performs the provider call itself.
abstract interface class ReviewRepairGenerator {
  Future<ReviewRepairResult> generateProposal({
    required ReviewRepairRequest request,
    TypedReviewSnapshot? snapshot,
    Duration timeout = const Duration(seconds: 60),
  });
}

/// Proposal-first AI repair for one review question.
///
/// Responsibilities: resolve the active text engine, build the bounded prompt,
/// parse the fixed JSON contract, canonicalize against the current question,
/// validate structure and LaTeX locally, and return a proposal. It never
/// mutates a review item, never writes storage and never touches the typed
/// review envelope.
class ReviewRepairService implements ReviewRepairGenerator {
  const ReviewRepairService({
    required AiEngineRepository engineRepository,
    LlmApiClient apiClient = const LlmApiClient(),
  })  : _engineRepository = engineRepository,
        _apiClient = apiClient;

  static const Duration _maximumTimeout = Duration(seconds: 90);
  static const int _maximumContentCharacters = 2000;
  static const int _maximumOptionCharacters = 400;
  static const int _maximumAnswerCharacters = 800;
  static const int _maximumExplanationCharacters = 4000;

  static const Set<String> _contractKeys = <String>{
    'question_number',
    'content',
    'options',
    'standard_answer',
    'explanation',
  };

  final AiEngineRepository _engineRepository;
  final LlmApiClient _apiClient;

  @override
  Future<ReviewRepairResult> generateProposal({
    required ReviewRepairRequest request,
    TypedReviewSnapshot? snapshot,
    Duration timeout = _maximumTimeout,
  }) async {
    final target = request.target;
    if (target.fields.isEmpty) {
      return const ReviewRepairResult.rejected(ReviewRepairOutcome.notEligible);
    }

    final unrebuildable = _unrebuildableField(request, snapshot);
    if (unrebuildable != null) {
      return ReviewRepairResult.rejected(
        ReviewRepairOutcome.unsupportedTargetField,
        diagnostics: <String>[unrebuildable.wireKey],
      );
    }

    final AiEngineProfile? profile;
    try {
      profile = await _engineRepository.getActiveTextEngine();
    } catch (_) {
      return const ReviewRepairResult.rejected(
        ReviewRepairOutcome.providerFailure,
      );
    }
    if (profile == null) {
      return const ReviewRepairResult.rejected(
        ReviewRepairOutcome.noActiveEngine,
      );
    }

    final String response;
    try {
      response = await _apiClient.callText(
        profile: profile,
        prompt: _buildPrompt(request),
        temperature: 0,
        maxTokens: 4096,
        jsonResponse: true,
        timeout: _effectiveTimeout(timeout),
      );
    } catch (_) {
      return const ReviewRepairResult.rejected(
        ReviewRepairOutcome.providerFailure,
      );
    }

    final _ReviewRepairResponseInspection responseInspection;
    try {
      responseInspection = _inspectResponse(response);
    } catch (_) {
      _recordResponseInspection(
        profile: profile,
        inspection: _ReviewRepairResponseInspection(
          decoded: null,
          jsonDecodeSucceeded: false,
          decodedTopLevelType: 'unavailable',
          extraKeyCount: 0,
          missingKeyCount: _contractKeys.length,
          classification: _ReviewRepairResponseClassification.parseFailure,
        ),
      );
      return const ReviewRepairResult.rejected(
        ReviewRepairOutcome.invalidJson,
        diagnostics: <String>['repair_parse_failure'],
      );
    }
    _recordResponseInspection(
      profile: profile,
      inspection: responseInspection,
    );
    if (!responseInspection.isValid) {
      return ReviewRepairResult.rejected(
        ReviewRepairOutcome.invalidJson,
        diagnostics: <String>[responseInspection.classification.wireName],
      );
    }
    final decoded = responseInspection.decoded!;

    if (_readQuestionNumber(decoded['question_number']) !=
        target.questionNumber) {
      return const ReviewRepairResult.rejected(
        ReviewRepairOutcome.questionIdentityChanged,
      );
    }

    final changed = <ReviewRepairField>[];
    final canonical = _canonicalize(request, decoded);
    for (final field in ReviewRepairField.values) {
      if (ReviewRepairEdit.digestSourceFor(field, request.inputDraft) !=
          ReviewRepairEdit.digestSourceFor(field, canonical)) {
        changed.add(field);
      }
    }
    if (changed.isEmpty) {
      return const ReviewRepairResult.rejected(ReviewRepairOutcome.emptyResult);
    }

    final outOfScope = changed.where((field) => !target.allows(field)).toList();
    if (outOfScope.isNotEmpty) {
      return ReviewRepairResult.rejected(
        ReviewRepairOutcome.unexpectedFieldChange,
        diagnostics: <String>[for (final field in outOfScope) field.wireKey],
      );
    }

    if (changed.contains(ReviewRepairField.options) &&
        !_optionShapePreserved(request.inputDraft.options, canonical.options)) {
      return const ReviewRepairResult.rejected(
        ReviewRepairOutcome.unsupportedOptionChange,
      );
    }

    // Deterministic structure-preserving LaTeX repair, so the proposal text is
    // exactly what the typed commit will finalize.
    final audited = auditFinalQuestionLatex(canonical.toMap());
    final proposed = _withAuditedText(canonical, audited.question);
    final targetWireKeys = <String>{
      for (final field in target.fields) field.wireKey,
    };
    final invalidTargetFields = audited.invalidFields
        .where(targetWireKeys.contains)
        .toList(growable: false);
    final remainingInvalidFields = audited.invalidFields
        .where((field) => !targetWireKeys.contains(field))
        .toList(growable: false);

    final structuralValid = _validateStructure(request, proposed);
    final latexValid = invalidTargetFields.isEmpty;
    final validation = ReviewRepairValidation(
      structuralValid: structuralValid,
      latexValid: latexValid,
      fieldsInScope: true,
      remainingDiagnostics: <String>[
        for (final field in remainingInvalidFields)
          '${ReviewRepairPolicy.latexUnrenderableCode}:$field',
      ],
    );

    if (!structuralValid) {
      return const ReviewRepairResult.rejected(
        ReviewRepairOutcome.structuralInvalid,
      );
    }
    if (!latexValid) {
      return ReviewRepairResult.rejected(
        ReviewRepairOutcome.latexStillInvalid,
        diagnostics: validation.remainingDiagnostics,
      );
    }
    if (_unrebuildableResultText(request, proposed, snapshot) != null) {
      return const ReviewRepairResult.rejected(
        ReviewRepairOutcome.structuralInvalid,
      );
    }

    final proposal = ReviewRepairProposal(
      request: request,
      proposedDraft: proposed,
      changedFields: changed,
      validation: validation,
    );
    if (!proposal.applicable) {
      return const ReviewRepairResult.rejected(
        ReviewRepairOutcome.structuralInvalid,
      );
    }
    return ReviewRepairResult.ready(proposal);
  }

  Duration _effectiveTimeout(Duration timeout) =>
      timeout.compareTo(_maximumTimeout) > 0 ? _maximumTimeout : timeout;

  String _buildPrompt(ReviewRepairRequest request) {
    final draft = request.inputDraft;
    final number = request.target.questionNumber;
    final fields = <String>[
      for (final field in request.target.fields) field.wireKey,
    ];
    final input = const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'question_number': number,
      'type': draft.type.code,
      'content': _bounded(draft.content, _maximumContentCharacters),
      'options': <String>[
        for (final option in draft.options)
          _bounded(option, _maximumOptionCharacters),
      ],
      'standard_answer': _bounded(
        draft.standardAnswer,
        _maximumAnswerCharacters,
      ),
      'explanation': _bounded(
        draft.explanation,
        _maximumExplanationCharacters,
      ),
    });
    final rawExplanation = draft.rawExplanation?.trim();
    final sourceBlock = rawExplanation == null || rawExplanation.isEmpty
        ? ''
        : '\n该题解析的原始 OCR 文本（仅用于恢复表达式，不得整段照抄，'
            '不得据此改写其它字段）：\n'
            '${_bounded(rawExplanation, _maximumExplanationCharacters)}\n';

    return '''
你正在修补审校页面中【第 $number 题】已经解析出来的题目数据。
你的任务是修复已标记字段中的问题，不是重新解题，也不是重新出题。

硬性规则：
1. 只能输出第 $number 题；禁止新增题目；禁止输出数组；禁止输出 Markdown 代码块或解释性文字。
2. question_number 必须是 $number，不得修改。
3. 只允许修改这些字段：${fields.join(', ')}。
   其它字段必须原样返回，不得改写、删减或补充。
4. 不得删除与问题无关的正确文本；保留正确内容，只修复确有问题的部分。
5. 不得凭空新增题目、选项、答案或解析内容；不得改变题型、选项数量或选项标签（如 A.、B.）。
6. 修复 LaTeX 时必须依据题目上下文恢复正确表达式，保证定界符配对、环境完整（例如 begin/end 成对）。
   不要改变数学含义，也不要为了通过检查而删掉公式。
7. 无法确定时，请原样返回该字段的内容；不得猜测整题。
8. 只返回一个 JSON object，且只能包含 question_number、content、options、standard_answer、explanation 五个键。

当前已解析数据（JSON）：
$input
$sourceBlock
触发问题：${request.target.triggerCodes.join(', ')}
允许修改的字段：${fields.join(', ')}

请只返回 JSON object：
{
  "question_number": $number,
  "content": "...",
  "options": ["A. ...", "B. ..."],
  "standard_answer": "...",
  "explanation": "..."
}
''';
  }

  _ReviewRepairResponseInspection _inspectResponse(String response) {
    final trimmed = response.trim();
    dynamic decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (_) {
      try {
        decoded = jsonDecode(_extractJsonObject(trimmed));
      } catch (_) {
        return _ReviewRepairResponseInspection(
          decoded: null,
          jsonDecodeSucceeded: false,
          decodedTopLevelType: 'unavailable',
          extraKeyCount: 0,
          missingKeyCount: _contractKeys.length,
          classification: _ReviewRepairResponseClassification.jsonDecodeFailed,
        );
      }
    }
    if (decoded is! Map) {
      return _ReviewRepairResponseInspection(
        decoded: null,
        jsonDecodeSucceeded: true,
        decodedTopLevelType: _topLevelType(decoded),
        extraKeyCount: 0,
        missingKeyCount: _contractKeys.length,
        classification: _ReviewRepairResponseClassification.nonObject,
      );
    }
    final result = <String, dynamic>{};
    decoded.forEach((key, value) => result[key.toString()] = value);
    final extraKeyCount =
        result.keys.where((key) => !_contractKeys.contains(key)).length;
    final missingKeyCount =
        _contractKeys.where((key) => !result.containsKey(key)).length;
    return _ReviewRepairResponseInspection(
      decoded: extraKeyCount == 0 ? result : null,
      jsonDecodeSucceeded: true,
      decodedTopLevelType: 'object',
      extraKeyCount: extraKeyCount,
      missingKeyCount: missingKeyCount,
      classification: extraKeyCount == 0
          ? _ReviewRepairResponseClassification.validContent
          : _ReviewRepairResponseClassification.extraKeys,
    );
  }

  String _topLevelType(Object? value) => switch (value) {
        null => 'null',
        Map() => 'object',
        List() => 'array',
        String() => 'string',
        num() => 'number',
        bool() => 'boolean',
        _ => 'other',
      };

  void _recordResponseInspection({
    required AiEngineProfile profile,
    required _ReviewRepairResponseInspection inspection,
  }) {
    AppLogger.info(
      'Review repair response inspected',
      module: 'ReviewRepair',
      data: <String, Object?>{
        'providerKind':
            LlmProviderRegistry.kindForBaseUrl(profile.baseUrl).name,
        'modelId': profile.modelName,
        ...inspection.diagnosticData,
      },
    );
  }

  String _extractJsonObject(String text) {
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw const FormatException('no JSON object found');
    }
    return text.substring(start, end + 1);
  }

  QuestionDraft _canonicalize(
    ReviewRepairRequest request,
    Map<String, dynamic> decoded,
  ) {
    final input = request.inputDraft;
    final rawOptions = decoded['options'];
    return QuestionDraft(
      type: input.type,
      content: _readString(decoded['content'], fallback: input.content),
      options: rawOptions is List
          ? <String>[
              for (final option in rawOptions) option.toString().trim(),
            ]
          : input.options,
      standardAnswer: _readString(
        decoded['standard_answer'],
        fallback: input.standardAnswer,
      ),
      explanation: _readString(
        decoded['explanation'],
        fallback: input.explanation,
      ),
      // Raw provenance is frozen review input; a repair never rewrites it.
      rawExplanation: input.rawExplanation,
    );
  }

  QuestionDraft _withAuditedText(
    QuestionDraft draft,
    Map<String, dynamic> audited,
  ) {
    return QuestionDraft(
      type: draft.type,
      content: _readString(audited['content'], fallback: draft.content),
      options: draft.options,
      standardAnswer: _readString(
        audited['standard_answer'],
        fallback: draft.standardAnswer,
      ),
      explanation: _readString(
        audited['explanation'],
        fallback: draft.explanation,
      ),
      rawExplanation: draft.rawExplanation,
    );
  }

  bool _validateStructure(
    ReviewRepairRequest request,
    QuestionDraft proposed,
  ) {
    if (proposed.content.trim().isEmpty) return false;
    if (request.inputDraft.type != proposed.type) return false;
    if (_analyzerErrorCount(proposed) >
        _analyzerErrorCount(request.inputDraft)) {
      return false;
    }
    for (final code in request.target.triggerCodes) {
      if (!_triggerResolved(code, proposed)) return false;
    }
    return true;
  }

  bool _triggerResolved(String code, QuestionDraft proposed) {
    switch (code) {
      case 'dangling_latex':
        const checker = LatexSanityChecker();
        return !checker.hasDanglingDelimiters(proposed.content) &&
            !proposed.options.any(checker.hasDanglingDelimiters) &&
            !checker.hasDanglingDelimiters(proposed.standardAnswer) &&
            !checker.hasDanglingDelimiters(proposed.explanation);
      case 'empty_content':
        return proposed.content.trim().isNotEmpty;
      case 'choice_options_less_than_2':
        return meaningfulOptions(proposed.options).length >= 2;
      case 'choice_missing_answer':
        return isMeaningfulAnswer(proposed.standardAnswer);
      default:
        // `latex_unrenderable` is resolved by the field audit above.
        return true;
    }
  }

  int _analyzerErrorCount(QuestionDraft draft) {
    return ImportReviewAnalyzer.analyzeItems(<ImportReviewItem>[
      ImportReviewItem(
        draft: draft,
        metadata: ImportReviewMetadata.empty(),
        originalIndex: 0,
      ),
    ]).summary.errorCount;
  }

  /// Returns the first targeted field whose typed content cannot be rebuilt
  /// from text, or `null` when every targeted field supports a structural edit.
  ReviewRepairField? _unrebuildableField(
    ReviewRepairRequest request,
    TypedReviewSnapshot? snapshot,
  ) {
    if (snapshot == null) return null;
    for (final field in request.target.fields) {
      switch (field) {
        case ReviewRepairField.content:
          if (!reviewFieldSupportsStructuralEdit(snapshot.draft.stem)) {
            return field;
          }
        case ReviewRepairField.explanation:
          final explanation = snapshot.draft.explanation;
          if (explanation != null &&
              !reviewFieldSupportsStructuralEdit(explanation)) {
            return field;
          }
        case ReviewRepairField.options:
          for (final option in snapshot.draft.options) {
            if (!reviewFieldSupportsStructuralEdit(option.content)) {
              return field;
            }
          }
        case ReviewRepairField.standardAnswer:
          final answer = snapshot.draft.answer;
          if (answer is ContentAnswer &&
              !reviewFieldSupportsStructuralEdit(answer.content)) {
            return field;
          }
      }
    }
    return null;
  }

  /// Returns the first targeted field whose proposed text cannot be rebuilt
  /// structurally, or `null` when every proposed value is rebuildable.
  ReviewRepairField? _unrebuildableResultText(
    ReviewRepairRequest request,
    QuestionDraft proposed,
    TypedReviewSnapshot? snapshot,
  ) {
    if (snapshot == null) return null;
    for (final field in request.target.fields) {
      switch (field) {
        case ReviewRepairField.content:
          if (reviewFieldContentFromLegacyText(proposed.content) == null) {
            return field;
          }
        case ReviewRepairField.explanation:
          if (proposed.explanation.trim().isNotEmpty &&
              reviewFieldContentFromLegacyText(proposed.explanation) == null) {
            return field;
          }
        case ReviewRepairField.standardAnswer:
          if (proposed.standardAnswer.trim().isNotEmpty &&
              reviewFieldContentFromLegacyText(proposed.standardAnswer) ==
                  null) {
            return field;
          }
        case ReviewRepairField.options:
          for (final option in proposed.options) {
            final body = optionBody(option);
            if (body.trim().isNotEmpty &&
                reviewFieldContentFromLegacyText(body) == null) {
              return field;
            }
          }
      }
    }
    return null;
  }

  /// Mirrors `TypedReviewResultBuilder`'s legacy option split: the leading
  /// label must not change across a repair, so the typed commit can always bind
  /// the edited body to its original option.
  bool _optionShapePreserved(List<String> before, List<String> after) {
    if (before.length != after.length) return false;
    for (var index = 0; index < before.length; index++) {
      if (optionLabel(before[index]) != optionLabel(after[index])) return false;
    }
    return true;
  }

  String _bounded(String value, int maximum) {
    if (value.length <= maximum) return value;
    return value.substring(0, maximum);
  }

  int? _readQuestionNumber(Object? value) {
    return switch (value) {
      final int number => number,
      final num number => number.toInt(),
      final String number => int.tryParse(number.trim()),
      _ => null,
    };
  }

  String _readString(Object? value, {required String fallback}) {
    final text = value?.toString().trim();
    if (text == null || text.isEmpty) return fallback;
    return text;
  }
}

/// Defensive immutable copy of a review draft.
QuestionDraft freezeReviewDraft(QuestionDraft draft) {
  return QuestionDraft(
    type: draft.type,
    content: draft.content,
    options: List<String>.unmodifiable(draft.options),
    standardAnswer: draft.standardAnswer,
    explanation: draft.explanation,
    rawExplanation: draft.rawExplanation,
  );
}

final _optionPattern = RegExp(r'^([A-Za-z])\s*[.．、]\s*(.*)$', dotAll: true);

/// The legacy option label, parsed exactly like the typed commit builder does.
String optionLabel(String option) {
  final match = _optionPattern.firstMatch(option);
  return match == null ? option : match.group(1)!;
}

/// The legacy option body, parsed exactly like the typed commit builder does.
String optionBody(String option) {
  final match = _optionPattern.firstMatch(option);
  return match == null ? '' : match.group(2)!;
}

bool _sameList(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
