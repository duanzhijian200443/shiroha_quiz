import '../../domain/answers/answer_candidate.dart';
import '../../domain/content/content_node.dart';
import '../../domain/content/rich_content.dart';
import '../../domain/question/question_draft_v2.dart';
import '../study_query/study_query_ports.dart';
import 'ai_answer_provider.dart';
import 'answer_candidate_review_session.dart';

final _boundedTokenPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');

/// P7 implementation defaults for the I0 ContentAnswer complexity bound.
///
/// Numeric values are implementation defaults, not durable architecture
/// truth; they mirror the D1 adapter defaults at the Application trust
/// boundary so an alternate/injected provider port cannot smuggle an
/// over-limit answer past I0.
const int _maxProviderAnswerNodes = 64;
const int _maxProviderAnswerScalars = 8192;

/// Safe typed failures of the P7-I0 AI answer generation use case.
///
/// Semantics are frozen by the P7 contract. Target/content, provider/output,
/// and internal categories are distinct; provider categories map 1:1 from
/// [AiAnswerProviderFailure]. `cancelled`/superseded late results are normal
/// lifecycle outcomes ([AiAnswerGenerationDiscarded]), never failures.
enum AiAnswerGenerationFailure {
  questionMissing,
  questionNotTyped,
  unsupportedQuestionKind,
  unsupportedQuestionContent,
  invalidQuestionState,
  staleTarget,
  providerUnconfigured,
  providerAuthenticationFailed,
  providerRateLimited,
  providerTimeout,
  providerUnavailable,
  providerRejected,
  malformedProviderOutput,
  validationFailed,
  internalError,
}

final class AiAnswerGenerationException implements Exception {
  const AiAnswerGenerationException(this.failure);

  final AiAnswerGenerationFailure failure;

  @override
  String toString() {
    final detail = switch (failure) {
      AiAnswerGenerationFailure.questionMissing =>
        'The typed question does not exist.',
      AiAnswerGenerationFailure.questionNotTyped =>
        'The target question is not a typed question.',
      AiAnswerGenerationFailure.unsupportedQuestionKind =>
        'The question kind is not supported by AI answer generation.',
      AiAnswerGenerationFailure.unsupportedQuestionContent =>
        'The question content cannot be admitted for AI generation.',
      AiAnswerGenerationFailure.invalidQuestionState =>
        'The question state is invalid for AI generation.',
      AiAnswerGenerationFailure.staleTarget =>
        'The target changed during generation.',
      AiAnswerGenerationFailure.providerUnconfigured =>
        'No usable text engine is configured.',
      AiAnswerGenerationFailure.providerAuthenticationFailed =>
        'The provider rejected the credential.',
      AiAnswerGenerationFailure.providerRateLimited =>
        'The provider is rate limiting requests.',
      AiAnswerGenerationFailure.providerTimeout =>
        'The provider request timed out.',
      AiAnswerGenerationFailure.providerUnavailable =>
        'The provider is temporarily unavailable.',
      AiAnswerGenerationFailure.providerRejected =>
        'The provider rejected the request.',
      AiAnswerGenerationFailure.malformedProviderOutput =>
        'The provider output did not match the bounded envelope contract.',
      AiAnswerGenerationFailure.validationFailed =>
        'The provider answer failed strict typed validation.',
      AiAnswerGenerationFailure.internalError =>
        'AI answer generation encountered an internal error.',
    };
    return 'AiAnswerGenerationException(${failure.name}): $detail';
  }
}

/// Why a late generation result was discarded.
enum AiAnswerDiscardReason {
  /// The caller cancelled the generation for this target.
  cancelled,

  /// A newer generation for the same target superseded this one.
  superseded,
}

/// Sealed lifecycle outcome of one AI answer generation.
sealed class AiAnswerGenerationOutcome {
  const AiAnswerGenerationOutcome();
}

/// A valid, current generation: exactly one transient Candidate plus its
/// generic review session. Nothing is persisted.
final class AiAnswerGenerationGenerated extends AiAnswerGenerationOutcome {
  const AiAnswerGenerationGenerated({
    required this.candidate,
    required this.reviewSession,
  });

  final AnswerCandidate candidate;
  final AnswerCandidateReviewSession reviewSession;
}

/// A late result of a cancelled or superseded generation. Never creates a
/// Candidate, never exposes a review session, and never writes anything.
final class AiAnswerGenerationDiscarded extends AiAnswerGenerationOutcome {
  const AiAnswerGenerationDiscarded(this.reason);

  final AiAnswerDiscardReason reason;
}

/// Captured generation-start target snapshot.
final class _CapturedTarget {
  const _CapturedTarget({
    required this.storageId,
    required this.bankName,
    required this.draft,
  });

  final String storageId;
  final String bankName;
  final QuestionDraftV2 draft;
}

/// P7-I0 AI generation Application use case.
///
/// Chain: exact snapshot load -> safe-content admission (zero provider calls
/// on rejection) -> bounded AI provider -> exact target reload/revalidation
/// -> fill/noOp/replace classification -> one transient `AnswerCandidate`
/// with an `AiAnswerOrigin` -> the shared producer-neutral review session.
///
/// The use case owns logical per-target generation epochs: a new generation
/// for the same target supersedes the previous one, and `cancel(storageId)`
/// invalidates the current epoch. Late results (success or failure) of a
/// superseded/cancelled generation are discarded and never exposed.
///
/// Everything is transient: no persistence, no kernel, no transaction, no
/// RAG/File Library/Conversation access. The service never sends the current
/// answer, explanation, source/asset references, diagnostics, paths, or any
/// other non-admitted field to the provider.
final class AiAnswerGenerationService {
  AiAnswerGenerationService({
    required StudyQuestionQueryPort questionPort,
    required AiAnswerProviderPort providerPort,
    required String Function() idFactory,
    required DateTime Function() clock,
  })  : _questionPort = questionPort,
        _providerPort = providerPort,
        _idFactory = idFactory,
        _clock = clock;

  final StudyQuestionQueryPort _questionPort;
  final AiAnswerProviderPort _providerPort;
  final String Function() _idFactory;
  final DateTime Function() _clock;

  /// Transient per-target generation epochs; restart-safe (disappears).
  final Map<String, int> _epochs = <String, int>{};

  /// Targets whose current epoch was invalidated by an explicit [cancel].
  final Set<String> _cancelled = <String>{};

  /// Invalidates the current generation epoch for [storageId], if any.
  void cancel(String storageId) {
    _epochs[storageId] = (_epochs[storageId] ?? 0) + 1;
    _cancelled.add(storageId);
  }

  Future<AiAnswerGenerationOutcome> generateForQuestion({
    required String storageId,
  }) async {
    final epoch = (_epochs[storageId] ?? 0) + 1;
    _epochs[storageId] = epoch;
    _cancelled.remove(storageId);

    // 1. Initial authoritative read.
    final StudyQuestionRead? read;
    try {
      read = await _readDetail(storageId);
    } catch (_) {
      final late = _discardIfStale(storageId, epoch);
      if (late != null) return late;
      throw const AiAnswerGenerationException(
        AiAnswerGenerationFailure.internalError,
      );
    }
    final lateAfterRead = _discardIfStale(storageId, epoch);
    if (lateAfterRead != null) return lateAfterRead;

    final captured = _interpretRead(storageId, read);

    // 2. Complete question-level admission; any rejection is zero provider
    //    calls and zero mutation.
    _validateQuestionState(captured);
    _validateCurrentAnswer(captured);

    // 3. Build the egress-safe request (admission already passed; the safe
    //    factories are the second structural guard).
    final AiAnswerProviderRequest request;
    try {
      request = _buildRequest(captured);
    } catch (_) {
      throw const AiAnswerGenerationException(
        AiAnswerGenerationFailure.internalError,
      );
    }

    // 4. Cancellation check immediately before the provider call.
    final lateBeforeProvider = _discardIfStale(storageId, epoch);
    if (lateBeforeProvider != null) return lateBeforeProvider;

    // 5. Bounded provider call; cancellation takes precedence over any late
    //    provider result (success or failure).
    final AiAnswerProviderResult providerResult;
    try {
      providerResult = await _providerPort.generateAnswer(request);
    } on AiAnswerProviderException catch (error) {
      final late = _discardIfStale(storageId, epoch);
      if (late != null) return late;
      throw AiAnswerGenerationException(_mapProviderFailure(error.failure));
    } catch (_) {
      final late = _discardIfStale(storageId, epoch);
      if (late != null) return late;
      throw const AiAnswerGenerationException(
        AiAnswerGenerationFailure.internalError,
      );
    }
    final lateAfterProvider = _discardIfStale(storageId, epoch);
    if (lateAfterProvider != null) return lateAfterProvider;

    // 6. I0 trust-boundary validation of the typed result.
    final answer = _validateProviderAnswer(providerResult.answer, captured);

    // 7. Exact target reload and stale revalidation.
    final StudyQuestionRead? reloaded;
    try {
      reloaded = await _readDetail(storageId);
    } catch (_) {
      final late = _discardIfStale(storageId, epoch);
      if (late != null) return late;
      throw const AiAnswerGenerationException(
        AiAnswerGenerationFailure.internalError,
      );
    }
    final lateAfterReload = _discardIfStale(storageId, epoch);
    if (lateAfterReload != null) return lateAfterReload;
    _revalidateTarget(storageId, captured, reloaded);

    // 8. fill/noOp/replace classification against the ORIGINAL captured
    //    draft using existing structural equality.
    final currentAnswer = captured.draft.answer;
    final writeIntent = currentAnswer == null
        ? CandidateWriteIntent.fill
        : (currentAnswer == answer
            ? CandidateWriteIntent.noOp
            : CandidateWriteIntent.replace);

    // 9. Fresh bounded identities; invalid factory metadata fails closed.
    final String generationId;
    final String candidateId;
    try {
      generationId = _idFactory();
      candidateId = _idFactory();
    } catch (_) {
      throw const AiAnswerGenerationException(
        AiAnswerGenerationFailure.internalError,
      );
    }
    if (!_boundedTokenPattern.hasMatch(generationId)) {
      throw const AiAnswerGenerationException(
        AiAnswerGenerationFailure.internalError,
      );
    }
    if (!_boundedTokenPattern.hasMatch(candidateId)) {
      throw const AiAnswerGenerationException(
        AiAnswerGenerationFailure.internalError,
      );
    }

    // 10. Final synchronous construction. Every injected/local operation is
    //     normalized: an unexpected clock or construction failure maps to
    //     internalError; only provider provenance violating the typed
    //     provider contract (invalid providerProfileId) maps to
    //     validationFailed. No raw cause may escape.
    final DateTime generatedAt;
    try {
      generatedAt = _clock().toUtc();
    } catch (_) {
      throw const AiAnswerGenerationException(
        AiAnswerGenerationFailure.internalError,
      );
    }

    final AiAnswerOrigin origin;
    try {
      origin = AiAnswerOrigin(
        generationId: generationId,
        providerProfileId: providerResult.providerProfileId,
        generatedAtUtc: generatedAt,
      );
    } on FormatException {
      // Invalid providerProfileId violates the typed provider result
      // contract; fail closed without exposing the raw value.
      throw const AiAnswerGenerationException(
        AiAnswerGenerationFailure.validationFailed,
      );
    }

    final AnswerCandidate candidate;
    final AnswerCandidateReviewSession reviewSession;
    try {
      candidate = AnswerCandidate(
        candidateId: candidateId,
        targetStorageId: captured.storageId,
        targetBankName: captured.bankName,
        expectedDraft: captured.draft,
        answer: answer,
        reviewOnlyExplanation: null,
        writeIntent: writeIntent,
        origin: origin,
      );
      reviewSession = AnswerCandidateReviewSession(
        candidates: <AnswerCandidate>[candidate],
      );
    } catch (_) {
      throw const AiAnswerGenerationException(
        AiAnswerGenerationFailure.internalError,
      );
    }

    // 11. Final cancellation/supersession gate immediately before outcome
    //     exposure.
    final lateBeforeExposure = _discardIfStale(storageId, epoch);
    if (lateBeforeExposure != null) return lateBeforeExposure;

    return AiAnswerGenerationGenerated(
      candidate: candidate,
      reviewSession: reviewSession,
    );
  }

  // --- lifecycle ---

  AiAnswerGenerationDiscarded? _discardIfStale(
    String storageId,
    int epoch,
  ) {
    if (_epochs[storageId] == epoch) return null;
    return AiAnswerGenerationDiscarded(
      _cancelled.contains(storageId)
          ? AiAnswerDiscardReason.cancelled
          : AiAnswerDiscardReason.superseded,
    );
  }

  // --- reads ---

  Future<StudyQuestionRead?> _readDetail(String storageId) {
    final now = _clock().toUtc().millisecondsSinceEpoch ~/ 1000;
    return _questionPort.getStudyQuestionDetail(
      storageId,
      nowUnixSeconds: now,
    );
  }

  _CapturedTarget _interpretRead(String storageId, StudyQuestionRead? read) {
    if (read == null) {
      throw const AiAnswerGenerationException(
        AiAnswerGenerationFailure.questionMissing,
      );
    }
    switch (read) {
      case TypedStudyQuestionRead(
          :final questionId,
          :final bankName,
          :final draft
        ):
        if (questionId != storageId) {
          throw const AiAnswerGenerationException(
            AiAnswerGenerationFailure.internalError,
          );
        }
        return _CapturedTarget(
          storageId: storageId,
          bankName: bankName,
          draft: draft,
        );
      case LegacyStudyQuestionRead():
        throw const AiAnswerGenerationException(
          AiAnswerGenerationFailure.questionNotTyped,
        );
    }
  }

  void _revalidateTarget(
    String storageId,
    _CapturedTarget captured,
    StudyQuestionRead? reloaded,
  ) {
    final typed = switch (reloaded) {
      null => throw const AiAnswerGenerationException(
          AiAnswerGenerationFailure.staleTarget,
        ),
      TypedStudyQuestionRead(
        :final questionId,
        :final bankName,
        :final draft
      ) =>
        (questionId: questionId, bankName: bankName, draft: draft),
      LegacyStudyQuestionRead() => throw const AiAnswerGenerationException(
          AiAnswerGenerationFailure.staleTarget,
        ),
    };
    if (typed.questionId != storageId ||
        typed.bankName != captured.bankName ||
        typed.draft != captured.draft) {
      throw const AiAnswerGenerationException(
        AiAnswerGenerationFailure.staleTarget,
      );
    }
  }

  // --- admission ---

  void _validateQuestionState(_CapturedTarget captured) {
    final draft = captured.draft;
    switch (draft.kind) {
      case QuestionKind.singleChoice:
        if (draft.options.isEmpty) {
          throw const AiAnswerGenerationException(
            AiAnswerGenerationFailure.invalidQuestionState,
          );
        }
        for (final option in draft.options) {
          if (_containsUnsupportedContent(option.content)) {
            throw const AiAnswerGenerationException(
              AiAnswerGenerationFailure.unsupportedQuestionContent,
            );
          }
          if (!_hasVisiblePayload(option.content)) {
            throw const AiAnswerGenerationException(
              AiAnswerGenerationFailure.invalidQuestionState,
            );
          }
        }
      case QuestionKind.fillBlank || QuestionKind.shortAnswer:
        if (draft.options.isNotEmpty) {
          throw const AiAnswerGenerationException(
            AiAnswerGenerationFailure.invalidQuestionState,
          );
        }
    }
    if (_containsUnsupportedContent(draft.stem)) {
      throw const AiAnswerGenerationException(
        AiAnswerGenerationFailure.unsupportedQuestionContent,
      );
    }
    if (!_hasVisiblePayload(draft.stem)) {
      throw const AiAnswerGenerationException(
        AiAnswerGenerationFailure.invalidQuestionState,
      );
    }
    if (draft.assetRefs.isNotEmpty) {
      throw const AiAnswerGenerationException(
        AiAnswerGenerationFailure.unsupportedQuestionContent,
      );
    }
  }

  void _validateCurrentAnswer(_CapturedTarget captured) {
    final current = captured.draft.answer;
    if (current == null) return;
    switch (captured.draft.kind) {
      case QuestionKind.singleChoice:
        if (current is! ChoiceAnswer) {
          throw const AiAnswerGenerationException(
            AiAnswerGenerationFailure.invalidQuestionState,
          );
        }
        final optionIds =
            captured.draft.options.map((option) => option.optionId).toSet();
        final seen = <String>{};
        for (final id in current.optionIds) {
          if (!seen.add(id) || !optionIds.contains(id)) {
            throw const AiAnswerGenerationException(
              AiAnswerGenerationFailure.invalidQuestionState,
            );
          }
        }
      case QuestionKind.fillBlank || QuestionKind.shortAnswer:
        if (current is! ContentAnswer) {
          throw const AiAnswerGenerationException(
            AiAnswerGenerationFailure.invalidQuestionState,
          );
        }
    }
  }

  AiAnswerProviderRequest _buildRequest(_CapturedTarget captured) {
    final draft = captured.draft;
    return AiAnswerProviderRequest(
      kind: draft.kind,
      stem: AiAnswerSafeContent.from(draft.stem),
      options: <AiAnswerSafeOption>[
        for (final option in draft.options)
          AiAnswerSafeOption(
            optionId: option.optionId,
            label: option.label,
            content: AiAnswerSafeContent.from(option.content),
          ),
      ],
    );
  }

  // --- result validation ---

  QuestionAnswer _validateProviderAnswer(
    QuestionAnswer answer,
    _CapturedTarget captured,
  ) {
    switch (captured.draft.kind) {
      case QuestionKind.singleChoice:
        if (answer is! ChoiceAnswer) {
          throw const AiAnswerGenerationException(
            AiAnswerGenerationFailure.validationFailed,
          );
        }
        if (answer.optionIds.length != 1) {
          throw const AiAnswerGenerationException(
            AiAnswerGenerationFailure.validationFailed,
          );
        }
        final optionId = answer.optionIds.single;
        final exists = captured.draft.options.any(
          (option) => option.optionId == optionId,
        );
        if (!exists) {
          throw const AiAnswerGenerationException(
            AiAnswerGenerationFailure.validationFailed,
          );
        }
        return answer;
      case QuestionKind.fillBlank || QuestionKind.shortAnswer:
        if (answer is! ContentAnswer) {
          throw const AiAnswerGenerationException(
            AiAnswerGenerationFailure.validationFailed,
          );
        }
        if (answer.content.nodes.isEmpty ||
            !_hasVisiblePayload(answer.content) ||
            _containsUnsupportedContent(answer.content)) {
          throw const AiAnswerGenerationException(
            AiAnswerGenerationFailure.validationFailed,
          );
        }
        // I0 re-enforces the frozen ContentAnswer complexity bound at the
        // Application trust boundary; over-limit output fails closed.
        if (answer.content.nodes.length > _maxProviderAnswerNodes) {
          throw const AiAnswerGenerationException(
            AiAnswerGenerationFailure.validationFailed,
          );
        }
        if (_payloadScalars(answer.content) > _maxProviderAnswerScalars) {
          throw const AiAnswerGenerationException(
            AiAnswerGenerationFailure.validationFailed,
          );
        }
        return answer;
    }
  }

  // --- shared content helpers ---

  int _payloadScalars(RichContent content) {
    var total = 0;
    for (final node in content.nodes) {
      switch (node) {
        case TextNode(:final text):
          total += text.runes.length;
        case InlineMathNode(:final latex) || BlockMathNode(:final latex):
          total += latex.runes.length;
        case ImageNode() || TableNode():
          break; // Rejected by _containsUnsupportedContent before counting.
        case RawFallbackNode():
          break; // Already rejected before counting; never contributes.
      }
    }
    return total;
  }

  bool _containsUnsupportedContent(RichContent content) {
    return content.nodes.any(
      (node) =>
          node is RawFallbackNode || node is ImageNode || node is TableNode,
    );
  }

  bool _hasVisiblePayload(RichContent content) {
    for (final node in content.nodes) {
      switch (node) {
        case TextNode(:final text):
          if (text.trim().isNotEmpty) return true;
        case InlineMathNode(:final latex) || BlockMathNode(:final latex):
          if (latex.trim().isNotEmpty) return true;
        case ImageNode() || TableNode():
          return false;
        case RawFallbackNode():
          return false;
      }
    }
    return false;
  }

  AiAnswerGenerationFailure _mapProviderFailure(
    AiAnswerProviderFailure failure,
  ) {
    return switch (failure) {
      AiAnswerProviderFailure.providerUnconfigured =>
        AiAnswerGenerationFailure.providerUnconfigured,
      AiAnswerProviderFailure.providerAuthenticationFailed =>
        AiAnswerGenerationFailure.providerAuthenticationFailed,
      AiAnswerProviderFailure.providerRateLimited =>
        AiAnswerGenerationFailure.providerRateLimited,
      AiAnswerProviderFailure.providerTimeout =>
        AiAnswerGenerationFailure.providerTimeout,
      AiAnswerProviderFailure.providerUnavailable =>
        AiAnswerGenerationFailure.providerUnavailable,
      AiAnswerProviderFailure.providerRejected =>
        AiAnswerGenerationFailure.providerRejected,
      AiAnswerProviderFailure.malformedProviderOutput =>
        AiAnswerGenerationFailure.malformedProviderOutput,
      AiAnswerProviderFailure.validationFailed =>
        AiAnswerGenerationFailure.validationFailed,
      AiAnswerProviderFailure.internalError =>
        AiAnswerGenerationFailure.internalError,
    };
  }
}
