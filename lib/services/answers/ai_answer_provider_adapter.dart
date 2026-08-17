import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../application/answers/ai_answer_provider.dart';
import '../../data/models/ai_engine_profile.dart';
import '../../data/persistence/engine_credential_store.dart';
import '../../data/repositories/ai_engine_repository.dart';
import '../../domain/content/content_node.dart';
import '../../domain/content/rich_content.dart';
import '../../domain/question/question_draft_v2.dart';
import '../llm_providers/llm_provider_registry.dart';

/// Bounded production HTTP adapter for the P7 AI answer provider port.
///
/// Owns the P7 provider boundary: resolves the current active text engine,
/// builds an egress-safe JSON request, sends it with a finite timeout and a
/// raw-response byte bound enforced **while reading the stream**, extracts
/// only the final answer content (never reasoning/thought), and strictly
/// decodes the frozen P7 answer schema into a typed [QuestionAnswer].
///
/// Raw provider responses live only inside one adapter call: they are
/// bounded, never logged, never persisted, never returned, and never
/// included in exceptions. Credentials, base URLs, headers, and provider
/// bodies never appear in `toString()`, results, or logs.
///
/// This adapter deliberately does not route through the legacy
/// `LlmApiClient` / provider clients, whose reasoning fallback and
/// unbounded-body behavior are not P7-safe.
final class AiAnswerProviderAdapter implements AiAnswerProviderPort {
  AiAnswerProviderAdapter({
    required AiEngineRepository engineRepository,
    http.Client? httpClient,
    this.requestTimeout = const Duration(seconds: 120),
    this.maxOutputTokens = 2048,
    this.maxRawResponseBytes = 64 * 1024,
    this.maxAnswerNodes = 64,
    this.maxAnswerScalars = 8192,
  })  : _engineRepository = engineRepository,
        _httpClient = httpClient ?? http.Client();

  final AiEngineRepository _engineRepository;
  final http.Client _httpClient;

  /// Finite per-request timeout (implementation default: 120 seconds).
  final Duration requestTimeout;

  /// Bounded output-token request (implementation default: 2048).
  final int maxOutputTokens;

  /// Bounded raw HTTP response body in bytes (implementation default: 64 KiB).
  final int maxRawResponseBytes;

  /// Bounded ContentAnswer node count (implementation default: 64).
  final int maxAnswerNodes;

  /// Bounded total node payload Unicode scalars (implementation default: 8192).
  final int maxAnswerScalars;

  @override
  Future<AiAnswerProviderResult> generateAnswer(
    AiAnswerProviderRequest request,
  ) async {
    final profile = await _resolveActiveProfile();

    // Every construction step capable of throwing (kind resolution, request
    // body, URI parse — including the Gemini `?key=` URI) runs inside the
    // typed normalization boundary so a malformed custom base URL/model can
    // never surface a raw FormatException/URI text (which could carry the
    // credential) to the caller.
    try {
      final kind = LlmProviderRegistry.kindForBaseUrl(profile.baseUrl);
      final body = switch (kind) {
        LlmProviderKind.gemini => _buildGeminiBody(profile, request),
        LlmProviderKind.zhipu ||
        LlmProviderKind.openAiCompatible =>
          _buildChatCompletionsBody(profile, request),
      };
      final uri = _buildUri(kind, profile);

      final streamed = await _send(uri, profile, body);
      if (streamed.statusCode != 200) {
        await _discard(streamed);
        throw _statusFailure(streamed.statusCode);
      }
      final bytes = await _readBounded(streamed);
      final envelope = _decodeEnvelope(kind, bytes);
      final answer = _decodeAnswer(envelope, request.kind, request);
      return AiAnswerProviderResult(
        answer: answer,
        providerProfileId: profile.id,
      );
    } on AiAnswerProviderException {
      rethrow;
    } on TimeoutException {
      throw const AiAnswerProviderException(
        AiAnswerProviderFailure.providerTimeout,
      );
    } on http.ClientException {
      throw const AiAnswerProviderException(
        AiAnswerProviderFailure.providerUnavailable,
      );
    } on _ResponseTooLarge {
      throw const AiAnswerProviderException(
        AiAnswerProviderFailure.malformedProviderOutput,
      );
    } catch (_) {
      // Includes malformed provider configuration (raw URI/format failures):
      // mapped to one safe typed category; the raw cause (which may contain
      // the configured URI or, for Gemini, the credential) never escapes.
      throw const AiAnswerProviderException(
        AiAnswerProviderFailure.internalError,
      );
    }
  }

  // --- profile resolution ---

  Future<AiEngineProfile> _resolveActiveProfile() async {
    final AiEngineProfile? profile;
    try {
      profile = await _engineRepository.getActiveTextEngine();
    } on EngineCredentialException catch (error) {
      throw switch (error.failure) {
        EngineCredentialFailure.temporarilyUnavailable =>
          const AiAnswerProviderException(
            AiAnswerProviderFailure.providerUnavailable,
          ),
        EngineCredentialFailure.missing ||
        EngineCredentialFailure.dataCorrupt =>
          const AiAnswerProviderException(
            AiAnswerProviderFailure.internalError,
          ),
      };
    } catch (_) {
      throw const AiAnswerProviderException(
        AiAnswerProviderFailure.internalError,
      );
    }
    if (profile == null || !profile.isComplete) {
      throw const AiAnswerProviderException(
        AiAnswerProviderFailure.providerUnconfigured,
      );
    }
    return profile;
  }

  // --- request construction ---

  String _buildPrompt(AiAnswerProviderRequest request) {
    final buffer = StringBuffer();
    buffer.writeln(
      request.kind == QuestionKind.singleChoice
          ? '题目（单选题）：'
          : '题目（${request.kind == QuestionKind.fillBlank ? '填空题' : '简答题'}）：',
    );
    buffer.writeln(_renderContent(request.stem));
    if (request.kind == QuestionKind.singleChoice) {
      buffer.writeln('选项：');
      for (final option in request.options) {
        buffer.writeln(
          '${option.optionId}. ${option.label} — ${_renderContent(option.content)}',
        );
      }
    }
    buffer.writeln();
    buffer.writeln(_schemaInstruction(request));
    buffer.write(_answerOnlyInstruction);
    return buffer.toString();
  }

  String _renderContent(AiAnswerSafeContent content) {
    final buffer = StringBuffer();
    for (final node in content.nodes) {
      switch (node) {
        case AiAnswerSafeText(:final text):
          buffer.write(text);
        case AiAnswerSafeInlineMath(:final latex):
          buffer.write(r'$');
          buffer.write(latex);
          buffer.write(r'$');
        case AiAnswerSafeBlockMath(:final latex):
          buffer.write(r'$$');
          buffer.write(latex);
          buffer.write(r'$$');
      }
    }
    return buffer.toString();
  }

  String _schemaInstruction(AiAnswerProviderRequest request) {
    if (request.kind == QuestionKind.singleChoice) {
      final ids = request.options.map((option) => option.optionId).join('、');
      return '只输出一个 JSON 对象，不得包含任何其他文本，格式严格如下：\n'
          '{"schema_version":1,"answer":{"kind":"choice","option_id":"<选项ID>"}}\n'
          'option_id 必须且只能从以下选项 ID 中选择一个：$ids。\n'
          '不允许输出 option_ids、数组或多个选项。';
    }
    return '只输出一个 JSON 对象，不得包含任何其他文本，格式严格如下：\n'
        '{"schema_version":1,"answer":{"kind":"content","nodes":['
        '{"type":"text","text":"..."},'
        '{"type":"inline_math","latex":"..."},'
        '{"type":"block_math","latex":"..."}]}}\n'
        'nodes 不能为空；每个节点的 type 只能是 text、inline_math 或 '
        'block_math；text 节点必须包含非空 text 字段，数学节点必须包含非空 '
        'latex 字段。';
  }

  static const String _answerOnlyInstruction = '只输出最终答案，不要输出解释、理由或任何思考过程。';

  Map<String, dynamic> _buildChatCompletionsBody(
    AiEngineProfile profile,
    AiAnswerProviderRequest request,
  ) {
    return <String, dynamic>{
      'model': profile.modelName,
      'messages': [
        {'role': 'system', 'content': _answerOnlyInstruction},
        {'role': 'user', 'content': _buildPrompt(request)},
      ],
      'max_tokens': maxOutputTokens,
      'temperature': profile.temperature,
      'response_format': {'type': 'json_object'},
    };
  }

  Map<String, dynamic> _buildGeminiBody(
    AiEngineProfile profile,
    AiAnswerProviderRequest request,
  ) {
    return <String, dynamic>{
      'contents': [
        {
          'parts': [
            {'text': _buildPrompt(request)},
          ],
        },
      ],
      'generationConfig': {
        'temperature': profile.temperature,
        'maxOutputTokens': maxOutputTokens,
        'responseMimeType': 'application/json',
      },
    };
  }

  Uri _buildUri(LlmProviderKind kind, AiEngineProfile profile) {
    final base = profile.baseUrl;
    return switch (kind) {
      LlmProviderKind.gemini => Uri.parse(
          '$base/models/${profile.modelName}:generateContent?key=${profile.apiKey}',
        ),
      LlmProviderKind.zhipu => Uri.parse(
          base.endsWith('/v4')
              ? '$base/chat/completions'
              : '$base/v4/chat/completions',
        ),
      LlmProviderKind.openAiCompatible => Uri.parse(
          base.endsWith('/v1')
              ? '$base/chat/completions'
              : '$base/v1/chat/completions',
        ),
    };
  }

  // --- bounded transport ---

  Future<http.StreamedResponse> _send(
    Uri uri,
    AiEngineProfile profile,
    Map<String, dynamic> body,
  ) {
    final request = http.Request('POST', uri);
    request.headers['Content-Type'] = 'application/json';
    if (LlmProviderRegistry.kindForBaseUrl(profile.baseUrl) !=
        LlmProviderKind.gemini) {
      request.headers['Authorization'] = 'Bearer ${profile.apiKey}';
    }
    request.body = jsonEncode(body);
    return _httpClient.send(request).timeout(requestTimeout);
  }

  Future<Uint8List> _readBounded(http.StreamedResponse response) {
    final completer = Completer<Uint8List>();
    final builder = BytesBuilder(copy: false);
    var total = 0;
    late final StreamSubscription<List<int>> subscription;
    final timer = Timer(requestTimeout, () {
      subscription.cancel();
      if (!completer.isCompleted) {
        completer
            .completeError(TimeoutException('provider body read timed out'));
      }
    });
    subscription = response.stream.listen(
      (chunk) {
        total += chunk.length;
        if (total > maxRawResponseBytes) {
          // Fail closed on byte overflow: cancel the stream, never buffer
          // the overflow, and never expose or log the body.
          timer.cancel();
          subscription.cancel();
          if (!completer.isCompleted) {
            completer.completeError(const _ResponseTooLarge());
          }
          return;
        }
        builder.add(chunk);
      },
      onError: (Object error, StackTrace stackTrace) {
        timer.cancel();
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      },
      onDone: () {
        timer.cancel();
        if (!completer.isCompleted) {
          completer.complete(builder.takeBytes());
        }
      },
    );
    return completer.future;
  }

  /// A non-success provider response body is never needed: its stream is
  /// cancelled immediately without draining, so neither the raw-response byte
  /// bound nor the request timeout can be bypassed, no body is ever buffered,
  /// and the status mapping completes promptly. Cancellation noise (including
  /// transport-level teardown errors) is swallowed; the typed status failure
  /// has already been decided and never carries the body.
  Future<void> _discard(http.StreamedResponse response) async {
    try {
      final subscription = response.stream.listen(null);
      await subscription.cancel().timeout(requestTimeout);
    } catch (_) {
      // Best-effort cancellation; never surfaces transport noise or body.
    }
  }

  AiAnswerProviderException _statusFailure(int statusCode) {
    return switch (statusCode) {
      401 || 403 => const AiAnswerProviderException(
          AiAnswerProviderFailure.providerAuthenticationFailed,
        ),
      408 || 504 => const AiAnswerProviderException(
          AiAnswerProviderFailure.providerTimeout,
        ),
      429 => const AiAnswerProviderException(
          AiAnswerProviderFailure.providerRateLimited,
        ),
      >= 500 => const AiAnswerProviderException(
          AiAnswerProviderFailure.providerUnavailable,
        ),
      _ => const AiAnswerProviderException(
          AiAnswerProviderFailure.providerRejected,
        ),
    };
  }

  // --- envelope extraction ---

  Map<String, dynamic> _decodeEnvelope(
    LlmProviderKind kind,
    Uint8List bytes,
  ) {
    final String text;
    try {
      text = utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      throw const AiAnswerProviderException(
        AiAnswerProviderFailure.malformedProviderOutput,
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw const AiAnswerProviderException(
        AiAnswerProviderFailure.malformedProviderOutput,
      );
    }
    final String finalContent;
    try {
      finalContent = switch (kind) {
        LlmProviderKind.gemini => _geminiFinalContent(decoded),
        LlmProviderKind.zhipu ||
        LlmProviderKind.openAiCompatible =>
          _chatFinalContent(decoded),
      };
    } on AiAnswerProviderException {
      rethrow;
    } catch (_) {
      throw const AiAnswerProviderException(
        AiAnswerProviderFailure.malformedProviderOutput,
      );
    }
    final Object? envelope;
    try {
      envelope = jsonDecode(finalContent);
    } on FormatException {
      throw const AiAnswerProviderException(
        AiAnswerProviderFailure.malformedProviderOutput,
      );
    }
    if (envelope is! Map<String, dynamic>) {
      throw const AiAnswerProviderException(
        AiAnswerProviderFailure.malformedProviderOutput,
      );
    }
    return envelope;
  }

  /// Extracts ONLY `choices[0].message.content`; reasoning_content is never
  /// read, so a provider thought fallback can never become the answer.
  String _chatFinalContent(Object? decoded) {
    final choices = (decoded as Map<String, dynamic>?)?['choices'];
    if (choices is! List || choices.isEmpty) {
      throw const AiAnswerProviderException(
        AiAnswerProviderFailure.malformedProviderOutput,
      );
    }
    final message = (choices.first as Map<String, dynamic>?)?['message'];
    final content = (message as Map<String, dynamic>?)?['content'];
    if (content is! String || content.trim().isEmpty) {
      throw const AiAnswerProviderException(
        AiAnswerProviderFailure.malformedProviderOutput,
      );
    }
    return content;
  }

  /// Extracts the final answer text only: the first non-thought text part.
  /// Thought/reasoning parts are skipped and can never become the answer.
  String _geminiFinalContent(Object? decoded) {
    final candidates = (decoded as Map<String, dynamic>?)?['candidates'];
    if (candidates is! List || candidates.isEmpty) {
      throw const AiAnswerProviderException(
        AiAnswerProviderFailure.malformedProviderOutput,
      );
    }
    final content = (candidates.first as Map<String, dynamic>?)?['content'];
    final parts = (content as Map<String, dynamic>?)?['parts'];
    if (parts is! List) {
      throw const AiAnswerProviderException(
        AiAnswerProviderFailure.malformedProviderOutput,
      );
    }
    for (final part in parts) {
      if (part is! Map<String, dynamic>) continue;
      if (part['thought'] == true) continue;
      final text = part['text'];
      if (text is String && text.trim().isNotEmpty) {
        return text;
      }
    }
    throw const AiAnswerProviderException(
      AiAnswerProviderFailure.malformedProviderOutput,
    );
  }

  // --- strict answer schema validation ---

  /// Strict P7 decoder.
  ///
  /// Mapping contract (documented and pinned by tests):
  /// - envelope-level failures (invalid JSON, missing/wrong `schema_version`,
  ///   missing `answer`) -> [AiAnswerProviderFailure.malformedProviderOutput];
  /// - answer-level shape/type/option/content failures ->
  ///   [AiAnswerProviderFailure.validationFailed].
  QuestionAnswer _decodeAnswer(
    Map<String, dynamic> envelope,
    QuestionKind kind,
    AiAnswerProviderRequest request,
  ) {
    final schemaVersion = envelope['schema_version'];
    if (schemaVersion is! int || schemaVersion != 1) {
      throw const AiAnswerProviderException(
        AiAnswerProviderFailure.malformedProviderOutput,
      );
    }
    final answer = envelope['answer'];
    if (answer is! Map<String, dynamic>) {
      throw const AiAnswerProviderException(
        AiAnswerProviderFailure.malformedProviderOutput,
      );
    }
    if (kind == QuestionKind.singleChoice) {
      return _decodeChoiceAnswer(answer, request);
    }
    return _decodeContentAnswer(answer);
  }

  QuestionAnswer _decodeChoiceAnswer(
    Map<String, dynamic> answer,
    AiAnswerProviderRequest request,
  ) {
    if (answer['kind'] != 'choice') {
      throw const AiAnswerProviderException(
        AiAnswerProviderFailure.validationFailed,
      );
    }
    // The multi-ID form is explicitly rejected, never manufactured.
    if (answer.containsKey('option_ids') || answer.containsKey('options')) {
      throw const AiAnswerProviderException(
        AiAnswerProviderFailure.validationFailed,
      );
    }
    final optionId = answer['option_id'];
    if (optionId is! String || optionId.trim().isEmpty) {
      throw const AiAnswerProviderException(
        AiAnswerProviderFailure.validationFailed,
      );
    }
    final allowedIds = request.options.map((option) => option.optionId);
    if (!allowedIds.contains(optionId)) {
      throw const AiAnswerProviderException(
        AiAnswerProviderFailure.validationFailed,
      );
    }
    return ChoiceAnswer(optionIds: <String>[optionId]);
  }

  QuestionAnswer _decodeContentAnswer(Map<String, dynamic> answer) {
    if (answer['kind'] != 'content') {
      throw const AiAnswerProviderException(
        AiAnswerProviderFailure.validationFailed,
      );
    }
    final nodes = answer['nodes'];
    if (nodes is! List || nodes.isEmpty) {
      throw const AiAnswerProviderException(
        AiAnswerProviderFailure.validationFailed,
      );
    }
    if (nodes.length > maxAnswerNodes) {
      throw const AiAnswerProviderException(
        AiAnswerProviderFailure.validationFailed,
      );
    }
    final contentNodes = <ContentNode>[];
    var scalarCount = 0;
    for (final rawNode in nodes) {
      if (rawNode is! Map<String, dynamic>) {
        throw const AiAnswerProviderException(
          AiAnswerProviderFailure.validationFailed,
        );
      }
      final type = rawNode['type'];
      final ContentNode node;
      switch (type) {
        case 'text':
          final text = rawNode['text'];
          if (text is! String || text.trim().isEmpty) {
            throw const AiAnswerProviderException(
              AiAnswerProviderFailure.validationFailed,
            );
          }
          node = TextNode(text);
        case 'inline_math':
          final latex = rawNode['latex'];
          if (latex is! String || latex.trim().isEmpty) {
            throw const AiAnswerProviderException(
              AiAnswerProviderFailure.validationFailed,
            );
          }
          node = InlineMathNode(latex);
        case 'block_math':
          final latex = rawNode['latex'];
          if (latex is! String || latex.trim().isEmpty) {
            throw const AiAnswerProviderException(
              AiAnswerProviderFailure.validationFailed,
            );
          }
          node = BlockMathNode(latex);
        default:
          // Unsupported node types (including any raw/fallback form) fail
          // closed; a RawFallbackNode can never be created from output.
          throw const AiAnswerProviderException(
            AiAnswerProviderFailure.validationFailed,
          );
      }
      scalarCount += _nodeScalars(node);
      if (scalarCount > maxAnswerScalars) {
        throw const AiAnswerProviderException(
          AiAnswerProviderFailure.validationFailed,
        );
      }
      contentNodes.add(node);
    }
    return ContentAnswer(content: RichContent(nodes: contentNodes));
  }

  int _nodeScalars(ContentNode node) {
    return switch (node) {
      TextNode(:final text) => text.runes.length,
      InlineMathNode(:final latex) => latex.runes.length,
      BlockMathNode(:final latex) => latex.runes.length,
      ImageNode(:final altText) => (altText ?? '').runes.length,
      RawFallbackNode() => 0, // Unreachable: raw fallback is never created.
    };
  }
}

/// Internal overflow marker: the raw response exceeded the byte bound while
/// being read; the body is never buffered, exposed, or logged.
final class _ResponseTooLarge implements Exception {
  const _ResponseTooLarge();

  @override
  String toString() => 'Response exceeded the bounded byte limit.';
}
