import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/ai_config/ai_config_service.dart';
import 'package:shiroha_quiz/domain/ai_config/ai_config_contracts.dart';
import 'package:shiroha_quiz/ui/pages/ai_model_selector_screen.dart';
import 'package:shiroha_quiz/ui/pages/ai_engine_management_screen.dart';
import 'package:shiroha_quiz/ui/pages/ai_provider_settings_screen.dart';
import 'package:shiroha_quiz/ui/pages/ai_settings_screen.dart';
import 'package:shiroha_quiz/ui/theme/app_theme.dart';

void main() {
  testWidgets('AI service exposes capability, Agent and Provider IA', (
    tester,
  ) async {
    final service = _UiAiConfigService();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: AiSettingsScreen(configService: service),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('能力配置'), findsOneWidget);
    expect(find.text('文本模型'), findsOneWidget);
    expect(find.text('图片理解'), findsOneWidget);
    expect(find.text('文档识别'), findsOneWidget);
    expect(find.text('基础设置'), findsOneWidget);
    expect(find.text('API 提供商与密钥'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('ai-service-text-row')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AiModelSelectorScreen), findsOneWidget);
    expect(find.byType(AiEngineManagementScreen), findsNothing);
    expect(find.text('选择模型 · 文本模型'), findsOneWidget);
  });

  testWidgets('model selector confirms explicitly and cancel has zero mutation',
      (
    tester,
  ) async {
    final service = _UiAiConfigService();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme,
        home: _SelectorHost(service: service),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('open-selector')));
    await tester.pumpAndSettle();

    expect(find.text('Compatible Model'), findsOneWidget);
    expect(find.textContaining('Incompatible Model'), findsNothing);
    expect(service.applyCalls, 0);

    await tester.tap(
      find.byKey(const ValueKey<String>('model-compatible-model')),
    );
    await tester.pump();
    expect(service.applyCalls, 0);
    await tester.tap(
      find.byKey(const ValueKey<String>('model-confirm-button')),
    );
    await tester.pumpAndSettle();
    expect(service.applyCalls, 1);

    await tester.tap(find.byKey(const ValueKey<String>('open-selector')));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(service.applyCalls, 1);
  });

  testWidgets('incompatible models are collapsed and expose exact reason', (
    tester,
  ) async {
    final service = _UiAiConfigService();
    await tester.pumpWidget(
      MaterialApp(
        home: AiModelSelectorScreen(
          service: service,
          slot: AiCapabilitySlot.textModel,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Incompatible Model'), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey<String>('model-incompatible-toggle')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Incompatible Model'), findsOneWidget);
    expect(find.textContaining('不支持所需能力'), findsOneWidget);
  });

  testWidgets('Provider editor never pre-fills credential plaintext', (
    tester,
  ) async {
    final service = _UiAiConfigService();
    await tester.pumpWidget(
      MaterialApp(home: AiProviderSettingsScreen(service: service)),
    );
    await tester.pumpAndSettle();

    expect(find.text('已同步 2 个模型'), findsOneWidget);
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    final fieldFinder = find.byKey(
      const ValueKey<String>('provider-key-field'),
    );
    final field = tester.widget<TextFormField>(fieldFinder);
    final editable = tester.widget<EditableText>(
      find.descendant(of: fieldFinder, matching: find.byType(EditableText)),
    );
    expect(field.controller!.text, isEmpty);
    expect(editable.obscureText, isTrue);
    expect(
      tester
          .widget<DropdownButtonFormField<AiProviderKind>>(
            find.byKey(const ValueKey<String>('provider-kind-field')),
          )
          .onChanged,
      isNull,
    );
    expect(
      tester
          .widget<EditableText>(
            find.descendant(
              of: find.byKey(
                const ValueKey<String>('provider-base-url-field'),
              ),
              matching: find.byType(EditableText),
            ),
          )
          .readOnly,
      isTrue,
    );
    expect(find.text('已有模型时不可修改，请新建 Provider 实例'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('provider-test-connection')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('provider-sync-models')),
    );
    await tester.pumpAndSettle();
    expect(service.testConnectionCalls, 1);
    expect(service.syncCalls, 1);

    await tester.enterText(
      find.byKey(const ValueKey<String>('provider-name-field')),
      'Renamed Provider',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('provider-save-button')),
    );
    await tester.pumpAndSettle();
    expect(service.updateCalls, 1);
    expect(service.lastExpectedRevision, 3);
    expect(service.lastReplacementCredential, isNull);
  });

  testWidgets('Provider add requires an explicit credential and uses UI seam', (
    tester,
  ) async {
    final service = _UiAiConfigService();
    await tester.pumpWidget(
      MaterialApp(home: AiProviderSettingsScreen(service: service)),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('provider-add-button')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('provider-name-field')),
      'Second DeepSeek',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('provider-key-field')),
      'synthetic-secret',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('provider-base-url-field')),
      'https://second.example.invalid',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('provider-save-button')),
    );
    await tester.pumpAndSettle();

    expect(service.createCalls, 1);
  });

  testWidgets('first OCR binding uses the legacy zero temperature default', (
    tester,
  ) async {
    final service = _UiAiConfigService();
    await tester.pumpWidget(
      MaterialApp(
        home: AiModelSelectorScreen(
          service: service,
          slot: AiCapabilitySlot.documentRecognition,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('model-compatible-model')),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('model-confirm-button')),
    );
    await tester.pumpAndSettle();

    expect(service.lastAppliedSlot, AiCapabilitySlot.documentRecognition);
    expect(service.lastAppliedTemperature, 0.0);
  });

  testWidgets(
      'AI config pages share responsive hierarchy at narrow and desktop',
      (tester) async {
    final service = _UiAiConfigService();
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    for (final size in <Size>[
      const Size(390, 1000),
      const Size(700, 1000),
      const Size(1100, 1000),
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(1.3),
            ),
            child: child!,
          ),
          home: AiProviderSettingsScreen(service: service),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.darkTheme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(1.3),
            ),
            child: child!,
          ),
          home: AiModelSelectorScreen(
            service: service,
            slot: AiCapabilitySlot.textModel,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  });
}

class _SelectorHost extends StatelessWidget {
  const _SelectorHost({required this.service});

  final AiConfigPresentationService service;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: FilledButton(
          key: const ValueKey<String>('open-selector'),
          onPressed: () => Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => AiModelSelectorScreen(
                service: service,
                slot: AiCapabilitySlot.textModel,
              ),
            ),
          ),
          child: const Text('Open'),
        ),
      ),
    );
  }
}

final class _UiAiConfigService implements AiConfigPresentationService {
  int applyCalls = 0;
  int createCalls = 0;
  int updateCalls = 0;
  int testConnectionCalls = 0;
  int syncCalls = 0;
  int providerRevision = 2;
  int? lastExpectedRevision;
  String? lastReplacementCredential;
  AiCapabilitySlot? lastAppliedSlot;
  double? lastAppliedTemperature;

  static final provider = AiProviderRecord(
    providerId: 'provider-p',
    kind: AiProviderKind.deepseek,
    displayName: 'DeepSeek',
    baseUrl: 'https://api.example.invalid',
    state: AiProviderState.ready,
    revision: 2,
    createdAt: 1,
    updatedAt: 2,
  );

  static final compatible = AiModelRecord(
    modelRef: 'compatible-model',
    providerId: provider.providerId,
    canonicalModelId: 'compatible-canonical',
    displayName: 'Compatible Model',
    availability: AiModelAvailability.available,
    firstSeenAt: 1,
    lastSeenAt: 2,
  );

  static final incompatible = AiModelRecord(
    modelRef: 'incompatible-model',
    providerId: provider.providerId,
    canonicalModelId: 'incompatible-canonical',
    displayName: 'Incompatible Model',
    availability: AiModelAvailability.available,
    firstSeenAt: 1,
    lastSeenAt: 2,
  );

  @override
  Future<AiCapabilityBindingSummary?> bindingSummary(
    AiCapabilitySlot slot,
  ) async =>
      null;

  @override
  Future<List<AiModelCompatibility>> listModelsForSlot(
    AiCapabilitySlot slot,
  ) async =>
      <AiModelCompatibility>[
        AiModelCompatibility(
          model: compatible,
          provider: provider,
          capabilities: const <AiModelCapability, AiCapabilitySupport>{
            AiModelCapability.textInput: AiCapabilitySupport.supported,
            AiModelCapability.textOutput: AiCapabilitySupport.supported,
          },
          compatible: true,
          reasonCodes: const <String>[],
        ),
        AiModelCompatibility(
          model: incompatible,
          provider: provider,
          capabilities: const <AiModelCapability, AiCapabilitySupport>{
            AiModelCapability.textInput: AiCapabilitySupport.unsupported,
            AiModelCapability.textOutput: AiCapabilitySupport.supported,
          },
          compatible: false,
          reasonCodes: const <String>['unsupported:textInput'],
        ),
      ];

  @override
  Future<List<AiProviderOverview>> listProviders() async =>
      <AiProviderOverview>[
        AiProviderOverview(
          provider: AiProviderRecord(
            providerId: provider.providerId,
            kind: provider.kind,
            displayName: provider.displayName,
            baseUrl: provider.baseUrl,
            state: provider.state,
            revision: providerRevision,
            createdAt: provider.createdAt,
            updatedAt: provider.updatedAt,
          ),
          credentialState: AiCredentialState.present,
          modelCount: 2,
          hasModelAuthority: true,
        ),
      ];

  @override
  Future<void> applyBinding({
    required AiCapabilitySlot slot,
    required String modelRef,
    required int? expectedRevision,
    double temperature = 0.7,
    String reasoningEffort = '',
  }) async {
    applyCalls++;
    lastAppliedSlot = slot;
    lastAppliedTemperature = temperature;
  }

  @override
  Future<String> createProvider({
    required AiProviderKind kind,
    required String displayName,
    required String baseUrl,
    required String credential,
  }) async {
    createCalls++;
    return 'created-provider';
  }

  @override
  Future<void> updateProvider({
    required String providerId,
    required int expectedRevision,
    required AiProviderKind kind,
    required String displayName,
    required String baseUrl,
    String? replacementCredential,
  }) async {
    updateCalls++;
    lastExpectedRevision = expectedRevision;
    lastReplacementCredential = replacementCredential;
  }

  @override
  Future<void> testConnection(String providerId) async {
    testConnectionCalls++;
  }

  @override
  Future<void> testConnectionDraft({
    String? providerId,
    required AiProviderKind kind,
    required String baseUrl,
    String? credential,
  }) async {
    testConnectionCalls++;
  }

  @override
  Future<void> syncModels(String providerId) async {
    syncCalls++;
    providerRevision++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
