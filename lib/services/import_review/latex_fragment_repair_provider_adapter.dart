import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../application/import_review/latex_fragment_repair_provider.dart';
import '../../core/observability/app_logger.dart';
import '../../data/models/ai_engine_profile.dart';
import '../../data/persistence/engine_credential_store.dart';
import '../../data/repositories/ai_engine_repository.dart';
import '../llm_providers/llm_provider_registry.dart';

/// Dedicated bounded transport for one LaTeX fragment repair.
///
/// It intentionally bypasses the legacy provider clients: reasoning content
/// is observed only by length and is never returned as the repaired fragment.
final class LatexFragmentRepairProviderAdapter
    implements LatexFragmentRepairProviderPort {
  LatexFragmentRepairProviderAdapter({
    required AiEngineRepository engineRepository,
    http.Client? httpClient,
    this.maxOutputTokens = 1024,
    this.maxRawResponseBytes = 64 * 1024,
  })  : _engineRepository = engineRepository,
        _httpClient = httpClient ?? http.Client();

  static const Duration _maximumTimeout = Duration(seconds: 90);

  final AiEngineRepository _engineRepository;
  final http.Client _httpClient;
  final int maxOutputTokens;
  final int maxRawResponseBytes;

  @override
  Future<LatexFragmentProviderResult> repair(
    LatexFragmentProviderRequest request, {
    Duration timeout = _maximumTimeout,
  }) async {
    final profile = await _resolveActiveProfile();
    final effectiveTimeout =
        timeout.compareTo(_maximumTimeout) > 0 ? _maximumTimeout : timeout;
    int? httpStatus;
    try {
      final kind = LlmProviderRegistry.kindForBaseUrl(profile.baseUrl);
      final uri = _buildUri(kind, profile);
      final streamed = await _send(
        uri,
        profile,
        kind,
        _buildBody(kind, profile, request),
        effectiveTimeout,
      );
      httpStatus = streamed.statusCode;
      if (streamed.statusCode != 200) {
        await _discard(streamed, effectiveTimeout);
        final failure = _statusFailure(streamed.statusCode);
        _record(
          profile: profile,
          kind: kind,
          httpStatus: streamed.statusCode,
          inspection: _FragmentInspection.failure(failure),
        );
        throw LatexFragmentProviderException(failure);
      }
      final bytes = await _readBounded(streamed, effectiveTimeout);
      final inspection = _inspect(kind, bytes);
      if (inspection.failure case final failure?) {
        _record(
          profile: profile,
          kind: kind,
          httpStatus: streamed.statusCode,
          inspection: inspection,
        );
        throw LatexFragmentProviderException(failure);
      }
      final content = inspection.content!.trim();
      if (!_validOutput(content, request.maximumOutputScalars)) {
        const failure = LatexFragmentProviderFailure.providerOutputInvalid;
        _record(
          profile: profile,
          kind: kind,
          httpStatus: streamed.statusCode,
          inspection: inspection.withFailure(failure),
        );
        throw const LatexFragmentProviderException(failure);
      }
      _record(
        profile: profile,
        kind: kind,
        httpStatus: streamed.statusCode,
        inspection: inspection,
      );
      return LatexFragmentProviderResult(
        correctedLatex: content,
        providerProfileId: profile.id,
      );
    } on LatexFragmentProviderException {
      rethrow;
    } on TimeoutException {
      _recordTransportFailure(
        profile,
        httpStatus,
        LatexFragmentProviderFailure.providerTimeout,
      );
      throw const LatexFragmentProviderException(
        LatexFragmentProviderFailure.providerTimeout,
      );
    } on http.ClientException {
      _recordTransportFailure(
        profile,
        httpStatus,
        LatexFragmentProviderFailure.providerUnavailable,
      );
      throw const LatexFragmentProviderException(
        LatexFragmentProviderFailure.providerUnavailable,
      );
    } on _ResponseTooLarge {
      _recordTransportFailure(
        profile,
        httpStatus,
        LatexFragmentProviderFailure.providerInvalidEnvelope,
      );
      throw const LatexFragmentProviderException(
        LatexFragmentProviderFailure.providerInvalidEnvelope,
      );
    } catch (_) {
      _recordTransportFailure(
        profile,
        httpStatus,
        LatexFragmentProviderFailure.internalError,
      );
      throw const LatexFragmentProviderException(
        LatexFragmentProviderFailure.internalError,
      );
    }
  }

  Future<AiEngineProfile> _resolveActiveProfile() async {
    final AiEngineProfile? profile;
    try {
      profile = await _engineRepository.getActiveTextEngine();
    } on EngineCredentialException catch (error) {
      throw LatexFragmentProviderException(
        error.failure == EngineCredentialFailure.temporarilyUnavailable
            ? LatexFragmentProviderFailure.providerUnavailable
            : LatexFragmentProviderFailure.internalError,
      );
    } catch (_) {
      throw const LatexFragmentProviderException(
        LatexFragmentProviderFailure.internalError,
      );
    }
    if (profile == null || !profile.isComplete) {
      throw const LatexFragmentProviderException(
        LatexFragmentProviderFailure.providerUnconfigured,
      );
    }
    return profile;
  }

  Map<String, Object?> _buildBody(
    LlmProviderKind kind,
    AiEngineProfile profile,
    LatexFragmentProviderRequest request,
  ) {
    final prompt = _buildPrompt(request);
    if (kind == LlmProviderKind.gemini) {
      return <String, Object?>{
        'contents': <Object?>[
          <String, Object?>{
            'parts': <Object?>[
              <String, Object?>{'text': prompt},
            ],
          },
        ],
        'generationConfig': <String, Object?>{
          'temperature': 0,
          'maxOutputTokens': maxOutputTokens,
        },
      };
    }
    return <String, Object?>{
      'model': profile.modelName,
      'messages': <Object?>[
        <String, Object?>{
          'role': 'system',
          'content': '只返回修复后的 LaTeX 源码，不要 Markdown、JSON、解释或思考过程。',
        },
        <String, Object?>{'role': 'user', 'content': prompt},
      ],
      'max_tokens': maxOutputTokens,
      'temperature': 0,
    };
  }

  String _buildPrompt(LatexFragmentProviderRequest request) {
    final kind = request.nodeKind.wireName == 'inline_math' ? '行内' : '块级';
    return '''
下面的 $kind LaTeX fragment 无法渲染。只修复语法或结构问题，不要改变数学含义。
返回 fragment body 本身，不要包含外层数学定界符、Markdown、JSON、解释或思考过程。

前文：${request.precedingContext}
待修复 fragment：${request.originalLatex}
后文：${request.followingContext}
''';
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

  Future<http.StreamedResponse> _send(
    Uri uri,
    AiEngineProfile profile,
    LlmProviderKind kind,
    Map<String, Object?> body,
    Duration timeout,
  ) {
    final request = http.Request('POST', uri);
    request.headers['Content-Type'] = 'application/json';
    if (kind != LlmProviderKind.gemini) {
      request.headers['Authorization'] = 'Bearer ${profile.apiKey}';
    }
    request.body = jsonEncode(body);
    return _httpClient.send(request).timeout(timeout);
  }

  Future<Uint8List> _readBounded(
    http.StreamedResponse response,
    Duration timeout,
  ) {
    final completer = Completer<Uint8List>();
    final builder = BytesBuilder(copy: false);
    var total = 0;
    late final StreamSubscription<List<int>> subscription;
    final timer = Timer(timeout, () {
      subscription.cancel();
      if (!completer.isCompleted) {
        completer.completeError(TimeoutException('bounded response timeout'));
      }
    });
    subscription = response.stream.listen(
      (chunk) {
        total += chunk.length;
        if (total > maxRawResponseBytes) {
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
        if (!completer.isCompleted) completer.complete(builder.takeBytes());
      },
    );
    return completer.future;
  }

  Future<void> _discard(
    http.StreamedResponse response,
    Duration timeout,
  ) async {
    try {
      final subscription = response.stream.listen(null);
      await subscription.cancel().timeout(timeout);
    } catch (_) {
      // Best-effort only. No response body is read or surfaced.
    }
  }

  _FragmentInspection _inspect(LlmProviderKind kind, Uint8List bytes) {
    dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } catch (_) {
      return const _FragmentInspection.invalidEnvelope(false);
    }
    if (decoded is! Map) {
      return const _FragmentInspection.invalidEnvelope(true);
    }
    return kind == LlmProviderKind.gemini
        ? _inspectGemini(decoded)
        : _inspectChat(decoded);
  }

  _FragmentInspection _inspectChat(Map<dynamic, dynamic> decoded) {
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty || choices.first is! Map) {
      return _FragmentInspection.invalidEnvelope(
        true,
        choicesCount: choices is List ? choices.length : 0,
      );
    }
    final choice = choices.first as Map;
    final message = choice['message'];
    if (message is! Map) {
      return _FragmentInspection.invalidEnvelope(
        true,
        choicesCount: choices.length,
      );
    }
    final rawContent = message['content'];
    final rawReasoning = message['reasoning_content'];
    if (rawContent != null && rawContent is! String ||
        rawReasoning != null && rawReasoning is! String) {
      return _FragmentInspection.invalidEnvelope(
        true,
        choicesCount: choices.length,
        messagePresent: true,
      );
    }
    return _classify(
      envelopeDecoded: true,
      choicesCount: choices.length,
      messagePresent: true,
      finishReason: _finishReason(choice['finish_reason']),
      content: rawContent as String?,
      reasoning: rawReasoning as String?,
    );
  }

  _FragmentInspection _inspectGemini(Map<dynamic, dynamic> decoded) {
    final candidates = decoded['candidates'];
    if (candidates is! List || candidates.isEmpty || candidates.first is! Map) {
      return _FragmentInspection.invalidEnvelope(
        true,
        choicesCount: candidates is List ? candidates.length : 0,
      );
    }
    final candidate = candidates.first as Map;
    final content = candidate['content'];
    final parts = content is Map ? content['parts'] : null;
    if (parts is! List || parts.any((part) => part is! Map)) {
      return _FragmentInspection.invalidEnvelope(
        true,
        choicesCount: candidates.length,
      );
    }
    final contentBuffer = StringBuffer();
    final reasoningBuffer = StringBuffer();
    for (final rawPart in parts) {
      final part = rawPart as Map;
      final text = part['text'];
      if (text == null) continue;
      if (text is! String) {
        return _FragmentInspection.invalidEnvelope(
          true,
          choicesCount: candidates.length,
          messagePresent: true,
        );
      }
      if (part['thought'] == true) {
        reasoningBuffer.write(text);
      } else {
        contentBuffer.write(text);
      }
    }
    return _classify(
      envelopeDecoded: true,
      choicesCount: candidates.length,
      messagePresent: true,
      finishReason: _finishReason(candidate['finishReason']),
      content: contentBuffer.toString(),
      reasoning: reasoningBuffer.toString(),
    );
  }

  _FragmentInspection _classify({
    required bool envelopeDecoded,
    required int choicesCount,
    required bool messagePresent,
    required String? finishReason,
    required String? content,
    required String? reasoning,
  }) {
    final contentEmpty = content == null || content.trim().isEmpty;
    final reasoningEmpty = reasoning == null || reasoning.trim().isEmpty;
    final failure = switch ((finishReason, contentEmpty, reasoningEmpty)) {
      ('length', _, _) => LatexFragmentProviderFailure.providerFinishLength,
      (_, true, false) => LatexFragmentProviderFailure.providerReasoningOnly,
      (_, true, true) => LatexFragmentProviderFailure.providerEmptyContent,
      _ => null,
    };
    return _FragmentInspection(
      content: content,
      envelopeDecodeSucceeded: envelopeDecoded,
      choicesCount: choicesCount,
      messagePresent: messagePresent,
      finishReason: finishReason,
      contentNull: content == null,
      contentEmpty: contentEmpty,
      contentCharacterLength: content?.length ?? 0,
      reasoningContentNull: reasoning == null,
      reasoningContentEmpty: reasoningEmpty,
      reasoningContentCharacterLength: reasoning?.length ?? 0,
      failure: failure,
    );
  }

  String? _finishReason(Object? value) {
    final normalized = value?.toString().trim().toLowerCase();
    return switch (normalized) {
      null || '' => null,
      'stop' => 'stop',
      'length' || 'max_tokens' => 'length',
      _ => 'other',
    };
  }

  bool _validOutput(String value, int maximumScalars) {
    if (value.isEmpty || value.runes.length > maximumScalars) return false;
    if (value.contains('```')) return false;
    if (RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]').hasMatch(value)) {
      return false;
    }
    return !_containsMathDelimiter(value);
  }

  bool _containsMathDelimiter(String value) {
    for (var index = 0; index < value.length; index++) {
      if (_isEscaped(value, index)) continue;
      if (value[index] == r'$') return true;
      if (value.codeUnitAt(index) != 92 || index + 1 >= value.length) continue;
      if (const <String>{'(', ')', '[', ']'}.contains(value[index + 1])) {
        return true;
      }
    }
    return false;
  }

  bool _isEscaped(String value, int offset) {
    var slashCount = 0;
    for (var index = offset - 1;
        index >= 0 && value.codeUnitAt(index) == 92;
        index--) {
      slashCount++;
    }
    return slashCount.isOdd;
  }

  LatexFragmentProviderFailure _statusFailure(int statusCode) {
    return switch (statusCode) {
      401 || 403 => LatexFragmentProviderFailure.providerAuthenticationFailed,
      408 || 504 => LatexFragmentProviderFailure.providerTimeout,
      429 => LatexFragmentProviderFailure.providerRateLimited,
      >= 500 => LatexFragmentProviderFailure.providerUnavailable,
      _ => LatexFragmentProviderFailure.providerRejected,
    };
  }

  void _record({
    required AiEngineProfile profile,
    required LlmProviderKind kind,
    required int? httpStatus,
    required _FragmentInspection inspection,
  }) {
    AppLogger.info(
      'Review repair fragment provider response inspected',
      module: 'ReviewRepair',
      data: <String, Object?>{
        'providerKind': kind.name,
        'modelId': profile.modelName,
        'httpStatus': httpStatus,
        ...inspection.diagnosticData,
      },
    );
  }

  void _recordTransportFailure(
    AiEngineProfile profile,
    int? httpStatus,
    LatexFragmentProviderFailure failure,
  ) {
    _record(
      profile: profile,
      kind: LlmProviderRegistry.kindForBaseUrl(profile.baseUrl),
      httpStatus: httpStatus,
      inspection: _FragmentInspection.failure(failure),
    );
  }
}

final class _FragmentInspection {
  const _FragmentInspection({
    required this.content,
    required this.envelopeDecodeSucceeded,
    required this.choicesCount,
    required this.messagePresent,
    required this.finishReason,
    required this.contentNull,
    required this.contentEmpty,
    required this.contentCharacterLength,
    required this.reasoningContentNull,
    required this.reasoningContentEmpty,
    required this.reasoningContentCharacterLength,
    required this.failure,
  });

  const _FragmentInspection.invalidEnvelope(
    bool decoded, {
    int choicesCount = 0,
    bool messagePresent = false,
  }) : this(
          content: null,
          envelopeDecodeSucceeded: decoded,
          choicesCount: choicesCount,
          messagePresent: messagePresent,
          finishReason: null,
          contentNull: true,
          contentEmpty: true,
          contentCharacterLength: 0,
          reasoningContentNull: true,
          reasoningContentEmpty: true,
          reasoningContentCharacterLength: 0,
          failure: LatexFragmentProviderFailure.providerInvalidEnvelope,
        );

  const _FragmentInspection.failure(LatexFragmentProviderFailure failure)
      : this(
          content: null,
          envelopeDecodeSucceeded: false,
          choicesCount: 0,
          messagePresent: false,
          finishReason: null,
          contentNull: true,
          contentEmpty: true,
          contentCharacterLength: 0,
          reasoningContentNull: true,
          reasoningContentEmpty: true,
          reasoningContentCharacterLength: 0,
          failure: failure,
        );

  final String? content;
  final bool envelopeDecodeSucceeded;
  final int choicesCount;
  final bool messagePresent;
  final String? finishReason;
  final bool contentNull;
  final bool contentEmpty;
  final int contentCharacterLength;
  final bool reasoningContentNull;
  final bool reasoningContentEmpty;
  final int reasoningContentCharacterLength;
  final LatexFragmentProviderFailure? failure;

  _FragmentInspection withFailure(LatexFragmentProviderFailure value) {
    return _FragmentInspection(
      content: null,
      envelopeDecodeSucceeded: envelopeDecodeSucceeded,
      choicesCount: choicesCount,
      messagePresent: messagePresent,
      finishReason: finishReason,
      contentNull: contentNull,
      contentEmpty: contentEmpty,
      contentCharacterLength: contentCharacterLength,
      reasoningContentNull: reasoningContentNull,
      reasoningContentEmpty: reasoningContentEmpty,
      reasoningContentCharacterLength: reasoningContentCharacterLength,
      failure: value,
    );
  }

  Map<String, Object?> get diagnosticData => <String, Object?>{
        'responseEnvelopeDecodeSucceeded': envelopeDecodeSucceeded,
        'choicesCount': choicesCount,
        'messagePresent': messagePresent,
        'finishReason': finishReason,
        'contentNull': contentNull,
        'contentEmpty': contentEmpty,
        'contentCharacterLength': contentCharacterLength,
        'reasoningContentNull': reasoningContentNull,
        'reasoningContentEmpty': reasoningContentEmpty,
        'reasoningContentCharacterLength': reasoningContentCharacterLength,
        'failureClassification':
            failure?.wireName ?? 'provider_content_present',
      };
}

final class _ResponseTooLarge implements Exception {
  const _ResponseTooLarge();
}
