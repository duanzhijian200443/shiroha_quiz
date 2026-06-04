import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/services/llm_providers/llm_provider_client.dart';

void main() {
  group('AiEngineProfile', () {
    test('normalizes database rows into a stable provider contract', () {
      final profile = AiEngineProfile.fromMap(
        {
          'id': ' engine-1 ',
          'engine_type': 'vision',
          'name': ' Gemini Vision ',
          'api_key': ' key ',
          'base_url': ' https://generativelanguage.googleapis.com/ ',
          'model_name': ' gemini-2.0-flash ',
          'temperature': '0.25',
          'reasoning_effort': ' low ',
          'is_active': 1,
        },
        fallbackType: AiEngineType.text,
      );

      expect(profile.id, 'engine-1');
      expect(profile.engineType, AiEngineType.vision);
      expect(profile.name, 'Gemini Vision');
      expect(profile.apiKey, 'key');
      expect(profile.baseUrl, 'https://generativelanguage.googleapis.com');
      expect(profile.modelName, 'gemini-2.0-flash');
      expect(profile.temperature, 0.25);
      expect(profile.reasoningEffort, 'low');
      expect(profile.isActive, isTrue);
      expect(profile.isComplete, isTrue);
    });

    test('reports missing required provider fields without throwing', () {
      final profile = AiEngineProfile.fromMap(
        {
          'id': 'engine-2',
          'name': 'Broken',
          'temperature': null,
          'is_active': 0,
        },
        fallbackType: AiEngineType.vision,
      );

      expect(profile.engineType, AiEngineType.vision);
      expect(profile.temperature, 0.7);
      expect(profile.isActive, isFalse);
      expect(profile.isComplete, isFalse);
      expect(profile.missingFields, ['api_key', 'base_url', 'model_name']);
    });
  });

  group('LlmTextRequest', () {
    test('builds requests from AiEngineProfile values', () {
      final profile = AiEngineProfile.fromMap({
        'id': 'engine-3',
        'engine_type': 'text',
        'api_key': 'key',
        'base_url': 'https://api.example.com/',
        'model_name': 'model-a',
        'temperature': 0.9,
        'reasoning_effort': 'medium',
        'is_active': true,
      });

      final request = LlmTextRequest.fromProfile(
        profile: profile,
        prompt: 'hello',
      );

      expect(request.apiKey, 'key');
      expect(request.baseUrl, 'https://api.example.com');
      expect(request.model, 'model-a');
      expect(request.temperature, 0.9);
      expect(request.reasoningEffort, 'medium');
      expect(request.isComplete, isTrue);
    });

    test('preserves system and user prompts as provider-ready messages', () {
      final profile = AiEngineProfile.fromMap({
        'id': 'engine-4',
        'engine_type': 'text',
        'api_key': 'key',
        'base_url': 'https://api.example.com',
        'model_name': 'model-a',
      });

      final request = LlmTextRequest.fromProfile(
        profile: profile,
        systemPrompt: 'system rules',
        prompt: 'user task',
      );

      expect(request.chatMessages, [
        {'role': 'system', 'content': 'system rules'},
        {'role': 'user', 'content': 'user task'},
      ]);
      expect(request.combinedPrompt, 'system rules\n\nuser task');
    });
  });
}
