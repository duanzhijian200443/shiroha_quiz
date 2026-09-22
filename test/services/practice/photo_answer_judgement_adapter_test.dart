import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/practice/photo_answer_judgement.dart';
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';
import 'package:shiroha_quiz/services/llm_api_client.dart';
import 'package:shiroha_quiz/services/llm_providers/llm_provider_client.dart';
import 'package:shiroha_quiz/services/practice/photo_answer_judgement_adapter.dart';
import 'package:shiroha_quiz/services/vision_asset_builder.dart';

const _visionProfile = AiEngineProfile(
  id: 'vision-profile',
  engineType: AiEngineType.vision,
  name: 'Vision',
  apiKey: 'synthetic-key',
  baseUrl: 'https://example.invalid',
  modelName: 'synthetic-vision',
  temperature: 0.7,
  reasoningEffort: '',
  isActive: true,
);

final class _FakeEngineRepository extends Fake implements AiEngineRepository {
  _FakeEngineRepository({this.available = true});
  final bool available;
  @override
  Future<AiEngineProfile?> getActiveVisionEngine() async =>
      available ? _visionProfile : null;
  @override
  Future<AiEngineProfile?> getActiveOcrEngine() =>
      throw StateError('OCR forbidden');
}

final class _FakeVisionAssetBuilder extends Fake implements VisionAssetBuilder {
  int calls = 0;

  @override
  Future<LlmVisionAsset> buildInlineFileAsset(
    String filePath, {
    required String mimeType,
    required bool compressImage,
  }) async {
    calls++;
    return LlmVisionAsset.inline(
      mimeType: mimeType,
      base64Data: 'c3ludGhldGlj',
    );
  }
}

final class _FakeLlmApiClient extends Fake implements LlmApiClient {
  _FakeLlmApiClient({required this.response, this.failure});

  final String response;
  final Object? failure;
  int calls = 0;
  String? prompt;
  double? temperature;

  @override
  Future<String> callVision({
    required AiEngineProfile profile,
    required String prompt,
    required List<LlmVisionAsset> assets,
    double? temperature,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    expect(assets, hasLength(1));
    calls++;
    this.prompt = prompt;
    this.temperature = temperature;
    if (failure != null) throw failure!;
    return response;
  }
}

PhotoAnswerJudgementRequest request(PhotoAnswerQuestionKind kind) =>
    PhotoAnswerJudgementRequest(
        imagePath: 'synthetic.png',
        imageName: 'synthetic.png',
        kind: kind,
        questionText: 'QUESTION_SENTINEL',
        standardAnswerText: 'STANDARD_SENTINEL');
void main() {
  for (final kind in PhotoAnswerQuestionKind.values) {
    test('$kind sends all context and exactly one image request', () async {
      final api = _FakeLlmApiClient(
          response:
              '{"result":"correct","transcription":"0.5","feedback":"equivalent"}');
      final assets = _FakeVisionAssetBuilder();
      final result = await PhotoAnswerJudgementAdapter(
              engineRepository: _FakeEngineRepository(),
              apiClient: api,
              assetBuilder: assets)
          .judge(request(kind));
      expect(result.correctness, true);
      expect(api.calls, 1);
      expect(assets.calls, 1);
      expect(api.prompt, contains('QUESTION_SENTINEL'));
      expect(api.prompt, contains('STANDARD_SENTINEL'));
      expect(
          api.prompt,
          contains(kind == PhotoAnswerQuestionKind.fillBlank
              ? 'fill_blank'
              : 'short_answer'));
      expect(api.prompt, contains('不得因为知道标准答案而纠正学生答案'));
      expect(api.prompt, contains('不得补全学生没有写出的步骤'));
    });
  }
  for (final token in ['correct', 'incorrect', 'uncertain']) {
    test('strict $token decision and empty transcription', () {
      final result = PhotoAnswerJudgementAdapter.parse(
          jsonEncode({'result': token, 'transcription': '', 'feedback': ''}));
      expect(result.isSuccess, true);
      expect(
          result.correctness, token == 'uncertain' ? null : token == 'correct');
    });
  }
  for (final raw in [
    '',
    'correct',
    '{',
    '{"result":"unknown","transcription":"x","feedback":"x"}',
    '{"result":"correct","transcription":1,"feedback":"x"}'
  ]) {
    test('fails closed: $raw', () {
      expect(PhotoAnswerJudgementAdapter.parse(raw).failure,
          PhotoAnswerJudgementFailure.malformedResponse);
    });
  }
  test('one presentation fence accepted; extra prose rejected; bounds enforced',
      () {
    const valid = '{"result":"incorrect","transcription":"x","feedback":"y"}';
    expect(
        PhotoAnswerJudgementAdapter.parse('```json\n$valid\n```').correctness,
        false);
    expect(PhotoAnswerJudgementAdapter.parse('prefix $valid').isSuccess, false);
    for (final field in ['transcription', 'feedback']) {
      expect(
          PhotoAnswerJudgementAdapter.parse(jsonEncode({
            'result': 'correct',
            'transcription': '',
            'feedback': '',
            field: 'x' * 20001
          })).failure,
          PhotoAnswerJudgementFailure.outputTooLong);
    }
  });
  test('unavailable engine performs zero provider calls', () async {
    final api = _FakeLlmApiClient(response: 'unused');
    final result = await PhotoAnswerJudgementAdapter(
            engineRepository: _FakeEngineRepository(available: false),
            apiClient: api)
        .judge(request(PhotoAnswerQuestionKind.fillBlank));
    expect(result.failure, PhotoAnswerJudgementFailure.engineUnavailable);
    expect(api.calls, 0);
  });
  for (final failure in [
    StateError('synthetic'),
    TimeoutException('synthetic')
  ]) {
    test('provider failure is classified without raw data', () async {
      final result = await PhotoAnswerJudgementAdapter(
              engineRepository: _FakeEngineRepository(),
              apiClient: _FakeLlmApiClient(response: '', failure: failure),
              assetBuilder: _FakeVisionAssetBuilder())
          .judge(request(PhotoAnswerQuestionKind.shortAnswer));
      expect(
          result.failure,
          failure is TimeoutException
              ? PhotoAnswerJudgementFailure.timeout
              : PhotoAnswerJudgementFailure.providerFailure);
    });
  }
}
