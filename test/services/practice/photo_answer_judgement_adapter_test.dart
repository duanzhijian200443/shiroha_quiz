import 'package:shiroha_quiz/domain/assets/asset_ref.dart';
import 'package:shiroha_quiz/domain/assets/sourced_asset_ref.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/application/content/content_asset_authority.dart';
import 'package:shiroha_quiz/data/models/persisted_question.dart';
import 'package:shiroha_quiz/data/models/question.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/ui/models/practice_question_view.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
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
  Future<LlmVisionAsset> buildInlineImageBytes(List<int> bytes) async =>
      LlmVisionAsset.inline(
          mimeType: 'image/jpeg', base64Data: base64Encode(bytes));

  @override
  Future<LlmVisionAsset> buildInlineStrictFileAsset(String filePath) async {
    calls++;
    return LlmVisionAsset.inline(
      mimeType: 'image/jpeg',
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
  List<LlmVisionAsset> assets = [];
  double? temperature;

  @override
  Future<String> callVision({
    required AiEngineProfile profile,
    required String prompt,
    required List<LlmVisionAsset> assets,
    double? temperature,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    this.assets = List.of(assets);
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
        question: RichContent(nodes: [TextNode('QUESTION_SENTINEL')]),
        standardAnswer: RichContent(nodes: [TextNode('STANDARD_SENTINEL')]));
void main() {
  test('durable bytes builder emits decodable JPEG and rejects invalid bytes',
      () async {
    const builder = VisionAssetBuilder();
    final asset = await builder
        .buildInlineImageBytes(img.encodePng(img.Image(width: 2, height: 3)));
    expect(asset.mimeType, 'image/jpeg');
    final decoded =
        img.decodeJpg(Uint8List.fromList(base64Decode(asset.base64Data!)));
    expect(decoded?.width, 2);
    expect(decoded?.height, 3);
    await expectLater(
        builder.buildInlineImageBytes([1, 2, 3]), throwsFormatException);
  });
  test('undecodable student image fails closed before any provider call',
      () async {
    final dir = await Directory.systemTemp.createTemp('student_image_');
    try {
      final file = File('${dir.path}/student.png')
        ..writeAsBytesSync(<int>[1, 2, 3]);
      final api = _FakeLlmApiClient(response: 'unused');
      final result = await PhotoAnswerJudgementAdapter(
              engineRepository: _FakeEngineRepository(),
              contentAssetResolver: _FakeResolver(),
              apiClient: api,
              assetBuilder: const VisionAssetBuilder())
          .judge(PhotoAnswerJudgementRequest(
              imagePath: file.path,
              imageName: 'student.png',
              kind: PhotoAnswerQuestionKind.fillBlank,
              question: RichContent(nodes: [const TextNode('q')]),
              standardAnswer: RichContent(nodes: [const TextNode('a')])));
      expect(result.failure, PhotoAnswerJudgementFailure.invalidInput);
      expect(api.calls, 0);
    } finally {
      await dir.delete(recursive: true);
    }
  });
  RichContent content(List<ContentNode> nodes) => RichContent(nodes: nodes);
  ImageNode image(String id, {bool alt = false}) => ImageNode(
      sourceId: 'source',
      localAssetId: id,
      alternativeText: alt ? content([const TextNode('ALT')]) : null);
  final table = TableNode(
      structure: TableStructure(rows: [
    TableRow(cells: [
      TableCell(rowSpan: 2, content: content([const TextNode('cell')])),
      TableCell(
          columnSpan: 2,
          content: content([const InlineMathNode(r'x^2'), image('cell')]))
    ]),
    TableRow(cells: [
      TableCell(content: content([const BlockMathNode(r'\int_0^1 x dx')])),
      TableCell(content: content([const TextNode('last')]))
    ]),
  ]));
  for (final sample
      in <(String, List<ContentNode>, List<ContentNode>, List<String>)>[
    (
      'math',
      [const InlineMathNode(r'x^2'), const BlockMathNode(r'\frac{1}{2}')],
      [const TextNode('a')],
      []
    ),
    (
      'pure question image',
      [image('q1', alt: true)],
      [const TextNode('a')],
      ['q1']
    ),
    ('pure answer image', [const TextNode('q')], [image('a1')], ['a1']),
    (
      'ordered question and answer images',
      [image('q1'), image('q2')],
      [image('a1')],
      ['q1', 'q2', 'a1']
    ),
    ('question table cell image', [table], [const TextNode('a')], ['cell']),
    ('answer table cell image', [const TextNode('q')], [table], ['cell']),
  ]) {
    test('${sample.$1} preserves structure and exact asset order', () async {
      final resolver = _FakeResolver();
      for (var i = 0; i < sample.$4.length; i++) {
        resolver.values['source/${sample.$4[i]}'] = [i + 1, 7];
      }
      final api = _FakeLlmApiClient(
          response: '{"result":"correct","transcription":"","feedback":""}');
      final result = await PhotoAnswerJudgementAdapter(
              engineRepository: _FakeEngineRepository(),
              contentAssetResolver: resolver,
              apiClient: api,
              assetBuilder: _FakeVisionAssetBuilder())
          .judge(PhotoAnswerJudgementRequest(
              imagePath: 'student.png',
              imageName: 'student.png',
              kind: PhotoAnswerQuestionKind.shortAnswer,
              question: content(sample.$2),
              standardAnswer: content(sample.$3)));
      expect(result.isSuccess, true);
      expect(api.calls, 1);
      expect(resolver.calls, [for (final id in sample.$4) 'source/$id']);
      expect(api.assets.map((a) => a.base64Data).toList(), [
        for (var i = 0; i < sample.$4.length; i++) base64Encode([i + 1, 7]),
        'c3ludGhldGlj',
      ]);
      final prompt = api.prompt!;
      final json = jsonDecode(prompt.split('\n')[1]) as Map;
      expect(json['QUESTION'], isNotEmpty);
      expect(json['STANDARD_ANSWER'], isNotEmpty);
      expect(prompt, contains('${sample.$4.length + 1} = student_answer'));
      expect(prompt, isNot(contains('source/')));
      if (sample.$1 == 'math') {
        expect(json['QUESTION'], [
          {'type': 'inline_math', 'latex': r'x^2'},
          {'type': 'block_math', 'latex': r'\frac{1}{2}'},
        ]);
      }
      if (sample.$1.contains('table')) {
        final rows = (json[sample.$1.startsWith('question')
            ? 'QUESTION'
            : 'STANDARD_ANSWER'][0] as Map)['rows'] as List;
        expect(rows, hasLength(2));
        expect(rows[0]['cells'][0], {
          'rowSpan': 2,
          'columnSpan': 1,
          'content': [
            {'type': 'text', 'text': 'cell'}
          ]
        });
        expect(rows[0]['cells'][1]['columnSpan'], 2);
        expect(rows[0]['cells'][1]['content'][0],
            {'type': 'inline_math', 'latex': r'x^2'});
        expect(rows[0]['cells'][1]['content'][1], {
          'type': 'image',
          'asset': sample.$1.startsWith('question')
              ? 'question_image_1'
              : 'answer_image_1'
        });
        expect(rows[1]['cells'][0]['content'][0],
            {'type': 'block_math', 'latex': r'\int_0^1 x dx'});
      }
      if (sample.$1 == 'ordered question and answer images') {
        expect(
            prompt,
            contains(
                '1 = question_image_1\n2 = question_image_2\n3 = answer_image_1\n4 = student_answer'));
      }
      if (sample.$1 == 'pure question image') {
        expect(json['QUESTION'][0]['alt'], [
          {'type': 'text', 'text': 'ALT'}
        ]);
      }
    });
  }
  for (final inAnswer in [false, true]) {
    for (final raw in [false, true]) {
      test(
          'unavailable context fails before provider: answer=$inAnswer raw=$raw',
          () async {
        final bad = content([
          raw
              ? RawFallbackNode({'type': 'future', 'payload': 'RAW_SENTINEL'})
              : image('missing')
        ]);
        final good = content([const TextNode('ok')]);
        final api = _FakeLlmApiClient(response: 'unused');
        final result = await PhotoAnswerJudgementAdapter(
                engineRepository: _FakeEngineRepository(),
                contentAssetResolver: _FakeResolver(),
                apiClient: api,
                assetBuilder: _FakeVisionAssetBuilder())
            .judge(PhotoAnswerJudgementRequest(
                imagePath: 'student',
                imageName: 'student.png',
                kind: PhotoAnswerQuestionKind.fillBlank,
                question: inAnswer ? good : bad,
                standardAnswer: inAnswer ? bad : good));
        expect(
            result.failure,
            raw
                ? PhotoAnswerJudgementFailure.contextUnsupported
                : PhotoAnswerJudgementFailure.contextAssetUnavailable);
        expect(api.calls, 0);
      });
    }
  }
  for (final typed in [false, true]) {
    test(
        'Practice authoritative projection excludes all explanation content: typed=$typed',
        () async {
      final view = typed
          ? PracticeQuestionViewAdapter.fromPersisted(TypedPersistedQuestion(
              storageId: 'q',
              bankName: 'b',
              createdAt: 1,
              draft: QuestionDraftV2(
                  questionId: 'q',
                  sourceRefs: [SourceRef.document(sourceId: 'source')],
                  assetRefs: [
                    SourcedAssetRef(
                        sourceId: 'source',
                        asset: AssetRef(
                            assetId: 'EXPLANATION_SENTINEL',
                            kind: AssetKind.image))
                  ],
                  kind: QuestionKind.shortAnswer,
                  stem: content([const TextNode('QUESTION_SENTINEL')]),
                  answer: ContentAnswer(
                      content: content([const TextNode('STANDARD_SENTINEL')])),
                  explanation: content([
                    const TextNode('EXPLANATION_SENTINEL'),
                    image('EXPLANATION_SENTINEL')
                  ]))))
          : PracticeQuestionViewAdapter.fromLegacyQuestion(const Question(
              id: 'q',
              type: 3,
              content: 'QUESTION_SENTINEL',
              answer: 'STANDARD_SENTINEL',
              createdAt: 1,
              bankName: 'b',
              explanation: 'EXPLANATION_SENTINEL',
              rawExplanation: 'RAW_EXPLANATION_SENTINEL'));
      final resolver = _FakeResolver();
      final api = _FakeLlmApiClient(
          response: '{"result":"uncertain","transcription":"","feedback":""}');
      final result = await PhotoAnswerJudgementAdapter(
              engineRepository: _FakeEngineRepository(),
              contentAssetResolver: resolver,
              apiClient: api,
              assetBuilder: _FakeVisionAssetBuilder())
          .judge(PhotoAnswerJudgementRequest(
              imagePath: 'student',
              imageName: 'student.png',
              kind: PhotoAnswerQuestionKind.shortAnswer,
              question: view.photoAnswerQuestion!,
              standardAnswer: view.photoAnswerStandardAnswer!));
      expect(result.isSuccess, true);
      expect(api.prompt, contains('QUESTION_SENTINEL'));
      expect(api.prompt, contains('STANDARD_SENTINEL'));
      expect(api.prompt, isNot(contains('EXPLANATION_SENTINEL')));
      expect(api.prompt, isNot(contains('RAW_EXPLANATION_SENTINEL')));
      expect(resolver.calls, isEmpty);
      expect(api.assets, hasLength(1));
      expect(api.calls, 1);
    });
  }
  for (final kind in PhotoAnswerQuestionKind.values) {
    test('$kind sends all context and exactly one image request', () async {
      final api = _FakeLlmApiClient(
          response:
              '{"result":"correct","transcription":"0.5","feedback":"equivalent"}');
      final assets = _FakeVisionAssetBuilder();
      final result = await PhotoAnswerJudgementAdapter(
              contentAssetResolver: _FakeResolver(),
              engineRepository: _FakeEngineRepository(),
              apiClient: api,
              assetBuilder: assets)
          .judge(request(kind));
      expect(result.correctness, true);
      expect(api.calls, 1);
      expect(assets.calls, 1);
      expect(api.assets, hasLength(1));
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
            contentAssetResolver: _FakeResolver(),
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
              contentAssetResolver: _FakeResolver(),
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

final class _FakeResolver extends Fake implements ContentAssetResolver {
  final Map<String, List<int>> values = {};
  final List<String> calls = [];
  @override
  Future<List<int>?> resolveAssetBytesAsync(
      {required String sourceId, required String localAssetId}) async {
    final key = '$sourceId/$localAssetId';
    calls.add(key);
    return values[key];
  }
}
