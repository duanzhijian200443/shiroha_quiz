import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../data/models/ai_engine_profile.dart';
import '../data/repositories/ai_engine_repository.dart';
import '../utils/ai_data_sanitizer.dart';
import 'ai_prompts.dart';
import 'llm_api_client.dart';

enum StructuredQuestionMergeFailureType {
  invalidJson,
  emptyResponse,
  timeout,
  rateLimited,
  network,
  notConfigured,
  unknown,
}

class StructuredQuestionMergeException implements Exception {
  const StructuredQuestionMergeException._({
    required this.type,
    required this.safeMessage,
    this.causeType,
  });

  final StructuredQuestionMergeFailureType type;
  final String safeMessage;
  final String? causeType;

  @override
  String toString() {
    final cause = causeType == null ? '' : ', causeType: $causeType';
    return 'StructuredQuestionMergeException('
        'type: ${type.name}, message: $safeMessage$cause)';
  }
}

typedef StructuredQuestionMergeProfileLoader = Future<AiEngineProfile?>
    Function();
typedef StructuredQuestionMergeRequest = Future<String> Function(
  AiEngineProfile profile,
  String prompt,
);
typedef StructuredQuestionMergeParser = Future<List<Map<String, dynamic>>>
    Function(String responseText);

class StructuredQuestionMergeService {
  StructuredQuestionMergeService({
    LlmApiClient apiClient = const LlmApiClient(),
    AiEngineRepository? engineRepository,
  }) : this._(
          loadProfile: (engineRepository ?? AiEngineRepository.instance)
              .getActiveTextEngine,
          request: (profile, prompt) => apiClient.callText(
            profile: profile,
            prompt: prompt,
            temperature: 0.1,
            maxTokens: 8192,
            jsonResponse: true,
            timeout: const Duration(minutes: 3),
          ),
          parseResponse: _parseResponseInIsolate,
        );

  @visibleForTesting
  StructuredQuestionMergeService.forTesting({
    required StructuredQuestionMergeProfileLoader loadProfile,
    required StructuredQuestionMergeRequest request,
    StructuredQuestionMergeParser? parseResponse,
  }) : this._(
          loadProfile: loadProfile,
          request: request,
          parseResponse: parseResponse ?? _parseResponseInIsolate,
        );

  const StructuredQuestionMergeService._({
    required StructuredQuestionMergeProfileLoader loadProfile,
    required StructuredQuestionMergeRequest request,
    required StructuredQuestionMergeParser parseResponse,
  })  : _loadProfile = loadProfile,
        _request = request,
        _parseResponse = parseResponse;

  final StructuredQuestionMergeProfileLoader _loadProfile;
  final StructuredQuestionMergeRequest _request;
  final StructuredQuestionMergeParser _parseResponse;

  Future<List<Map<String, dynamic>>> merge(
    List<List<Map<String, dynamic>>> fileResults,
  ) async {
    if (fileResults.isEmpty) return [];
    if (fileResults.length == 1) return fileResults.first;

    var stage = _StructuredQuestionMergeStage.loadProfile;
    try {
      final profile = await _loadProfile();
      if (profile == null || !profile.isComplete) {
        throw _failure(
          StructuredQuestionMergeFailureType.notConfigured,
        );
      }

      final prompt =
          AiPrompts.mergeStructuredQuestions(jsonEncode(fileResults));
      stage = _StructuredQuestionMergeStage.request;
      final responseText = await _request(profile, prompt);
      if (responseText.trim().isEmpty) {
        throw _failure(
          StructuredQuestionMergeFailureType.emptyResponse,
        );
      }

      stage = _StructuredQuestionMergeStage.parse;
      return await _parseResponse(responseText);
    } on StructuredQuestionMergeException {
      rethrow;
    } catch (error) {
      throw _classifyFailure(error, stage);
    }
  }
}

Future<List<Map<String, dynamic>>> _parseResponseInIsolate(
  String responseText,
) {
  return compute(AiDataSanitizer.cleanAndParseJson, responseText);
}

enum _StructuredQuestionMergeStage {
  loadProfile,
  request,
  parse,
}

StructuredQuestionMergeException _classifyFailure(
  Object error,
  _StructuredQuestionMergeStage stage,
) {
  final type = switch (error) {
    TimeoutException() => StructuredQuestionMergeFailureType.timeout,
    FormatException() => StructuredQuestionMergeFailureType.invalidJson,
    SocketException() => StructuredQuestionMergeFailureType.network,
    HttpException() => StructuredQuestionMergeFailureType.network,
    http.ClientException() => StructuredQuestionMergeFailureType.network,
    _ when _looksRateLimited(error) =>
      StructuredQuestionMergeFailureType.rateLimited,
    _
        when stage == _StructuredQuestionMergeStage.parse &&
            _looksLikeInvalidJson(error) =>
      StructuredQuestionMergeFailureType.invalidJson,
    _ when _looksLikeNetworkFailure(error) =>
      StructuredQuestionMergeFailureType.network,
    _ => StructuredQuestionMergeFailureType.unknown,
  };

  return _failure(type, causeType: error.runtimeType.toString());
}

bool _looksRateLimited(Object error) {
  final message = error.toString().toLowerCase();
  return RegExp(r'(^|[^0-9])429([^0-9]|$)').hasMatch(message) ||
      message.contains('too many requests') ||
      message.contains('rate limit');
}

bool _looksLikeInvalidJson(Object error) {
  final message = error.toString().toLowerCase();
  return message.contains('json parse failed') ||
      message.contains('no json object or array') ||
      message.contains('json brackets are not balanced') ||
      message.contains('formatexception');
}

bool _looksLikeNetworkFailure(Object error) {
  final message = error.toString().toLowerCase();
  return message.contains('socketexception') ||
      message.contains('clientexception') ||
      message.contains('connection refused') ||
      message.contains('connection reset') ||
      message.contains('connection failed') ||
      message.contains('failed host lookup') ||
      message.contains('network is unreachable');
}

StructuredQuestionMergeException _failure(
  StructuredQuestionMergeFailureType type, {
  String? causeType,
}) {
  return StructuredQuestionMergeException._(
    type: type,
    safeMessage: switch (type) {
      StructuredQuestionMergeFailureType.invalidJson =>
        'The AI merge response was not valid JSON.',
      StructuredQuestionMergeFailureType.emptyResponse =>
        'The AI merge response was empty.',
      StructuredQuestionMergeFailureType.timeout =>
        'The AI merge operation timed out.',
      StructuredQuestionMergeFailureType.rateLimited =>
        'The AI merge request was rate limited.',
      StructuredQuestionMergeFailureType.network =>
        'The AI merge request failed because of a network error.',
      StructuredQuestionMergeFailureType.notConfigured =>
        'A complete text AI engine is not configured.',
      StructuredQuestionMergeFailureType.unknown =>
        'The AI merge operation failed.',
    },
    causeType: causeType,
  );
}
