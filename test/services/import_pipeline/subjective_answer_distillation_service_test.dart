import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/data/models/question_draft.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';
import 'package:shiroha_quiz/services/import_pipeline/subjective_answer_distillation_service.dart';
import 'package:shiroha_quiz/services/llm_api_client.dart';

import '../../support/unsupported_ai_engine_store.dart';

const _profile = AiEngineProfile(
  id: 'answer-distillation-test',
  engineType: AiEngineType.text,
  name: 'fake-text-engine',
  apiKey: 'test-key',
  baseUrl: 'https://example.invalid/v1',
  modelName: 'fake-model',
  temperature: 0,
  reasoningEffort: '',
  isActive: true,
);

const _question = QuestionDraft(
  type: QuestionType.shortAnswer,
  content: 'Synthetic subjective question',
  options: [],
  standardAnswer: '',
  explanation: 'Synthetic explanation used only for answer distillation.',
  rawExplanation: 'Raw provenance must not be sent.',
);

class _EngineRepository extends AiEngineRepository {
  _EngineRepository() : super(store: const UnsupportedAiEngineStore());

  @override
  Future<AiEngineProfile?> getActiveTextEngine() async => _profile;
}

class _RecordingClient extends LlmApiClient {
  _RecordingClient(this.response, {this.failure});

  final String response;
  final Object? failure;
  int callCount = 0;
  String? prompt;
  Duration? timeout;

  @override
  Future<String> callText({
    required AiEngineProfile profile,
    required String prompt,
    String? systemPrompt,
    double? temperature,
    String? reasoningEffort,
    int maxTokens = 8192,
    bool jsonResponse = false,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    callCount++;
    this.prompt = prompt;
    this.timeout = timeout;
    if (failure != null) throw failure!;
    return response;
  }
}

SubjectiveAnswerDistillationService _service(_RecordingClient client) {
  return SubjectiveAnswerDistillationService(
    engineRepository: _EngineRepository(),
    apiClient: client,
  );
}

void main() {
  test('applies a concise answer and sends only the allowed single question',
      () async {
    final client = _RecordingClient(
      '{"question_number":17,"standard_answer":"Concise conclusion","basis":"explanation"}',
    );

    final result = await _service(client).distill(
      questionNumber: 17,
      question: _question,
      isStemOnly: false,
    );

    expect(result.applied, isTrue);
    expect(result.outcome, SubjectiveAnswerDistillationOutcome.applied);
    expect(result.snapshotStatus, 'ai_applied');
    expect(result.standardAnswer, 'Concise conclusion');
    expect(result.diagnostics, contains('answer_distillation_applied'));
    expect(client.callCount, 1);
    expect(client.timeout, lessThanOrEqualTo(const Duration(seconds: 30)));
    expect(client.prompt, contains('"question_number":17'));
    expect(client.prompt, contains('"type":3'));
    expect(client.prompt, contains(_question.content));
    expect(client.prompt, contains(_question.explanation));
    expect(client.prompt, contains('你不是重新解题'));
    expect(client.prompt, contains('basis 必须固定为 explanation'));
    expect(client.prompt, isNot(contains(_question.rawExplanation!)));
    expect(client.prompt, isNot(contains('filePath')));
  });

  test('rejects changed number, empty, placeholder, and verbose answers',
      () async {
    final cases = <String, String>{
      '{"question_number":18,"standard_answer":"Conclusion","basis":"explanation"}':
          'answer_distillation_rejected_question_number_changed',
      '{"question_number":17,"standard_answer":"","basis":"explanation"}':
          'answer_distillation_rejected_empty',
      '{"question_number":17,"standard_answer":"见解析","basis":"explanation"}':
          'answer_distillation_rejected_placeholder',
      '{"question_number":17,"standard_answer":"${_question.explanation}","basis":"explanation"}':
          'answer_distillation_rejected_too_verbose',
      '{"question_number":17,"standard_answer":"${List.filled(241, 'x').join()}","basis":"explanation"}':
          'answer_distillation_rejected_too_verbose',
      '{"question_number":17,"standard_answer":"Conclusion","basis":"independent"}':
          'answer_distillation_rejected_basis',
    };

    for (final entry in cases.entries) {
      final result = await _service(_RecordingClient(entry.key)).distill(
        questionNumber: 17,
        question: _question,
        isStemOnly: false,
      );
      expect(result.applied, isFalse, reason: entry.value);
      expect(
        result.outcome,
        SubjectiveAnswerDistillationOutcome.rejected,
        reason: entry.value,
      );
      expect(result.snapshotStatus, 'ai_rejected', reason: entry.value);
      expect(result.safeReasonCode, entry.value, reason: entry.value);
      expect(result.standardAnswer, isNull, reason: entry.value);
      expect(result.diagnostics, contains(entry.value), reason: entry.value);
    }
  });

  test('arrays, non-json, code fences, and provider failures are safe',
      () async {
    for (final client in <_RecordingClient>[
      _RecordingClient(
        '[{"question_number":17,"standard_answer":"A","basis":"explanation"}]',
      ),
      _RecordingClient('not-json'),
      _RecordingClient(
        '{"question_number":17,"standard_answer":"```answer```","basis":"explanation"}',
      ),
      _RecordingClient(
        '',
        failure: const FormatException('SENSITIVE_PROVIDER_BODY'),
      ),
    ]) {
      final result = await _service(client).distill(
        questionNumber: 17,
        question: _question,
        isStemOnly: false,
      );
      expect(result.applied, isFalse);
      expect(result.outcome, SubjectiveAnswerDistillationOutcome.failed);
      expect(result.snapshotStatus, 'ai_failed');
      expect(result.standardAnswer, isNull);
      expect(result.diagnostics, contains('answer_distillation_failed'));
      expect(
        result.diagnostics.join(),
        isNot(contains('SENSITIVE_PROVIDER_BODY')),
      );
      expect(
        result.safeReasonCode,
        'answer_distillation_failed',
      );
    }
  });

  test('non-candidates never call the provider', () async {
    for (final question in [
      _question.copyWith(standardAnswer: 'Existing answer'),
      _question.copyWith(explanation: ''),
      _question.copyWith(content: '证明该命题成立'),
      _question.copyWith(explanation: '推导完成。答案为：42'),
    ]) {
      final client = _RecordingClient(
        '{"question_number":17,"standard_answer":"Conclusion","basis":"explanation"}',
      );

      final result = await _service(client).distill(
        questionNumber: 17,
        question: question,
        isStemOnly: false,
      );

      expect(result.applied, isFalse);
      expect(result.outcome, SubjectiveAnswerDistillationOutcome.rejected);
      expect(client.callCount, 0);
    }
  });

  test('snapshot reasons reject prefixed payloads and outcome mismatches', () {
    const rejected = SubjectiveAnswerDistillationResult.rejected(
      diagnostics: [
        'answer_distillation_rejected_sensitive_provider_body',
      ],
    );
    const failed = SubjectiveAnswerDistillationResult.failed(
      diagnostics: ['answer_distillation_rejected_basis'],
    );
    const failedWithPayload = SubjectiveAnswerDistillationResult.failed(
      diagnostics: [
        'answer_distillation_failure_type:SENSITIVEPROVIDERBODY123',
      ],
    );

    expect(rejected.safeReasonCode, 'answer_distillation_rejected');
    expect(rejected.safeReasonCode, isNot(contains('sensitive_provider_body')));
    expect(failed.safeReasonCode, 'answer_distillation_failed');
    expect(failedWithPayload.safeReasonCode, 'answer_distillation_failed');
    expect(
      failedWithPayload.safeReasonCode,
      isNot(contains('SENSITIVEPROVIDERBODY123')),
    );
  });
}
