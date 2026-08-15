import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/agent/agent_config.dart';
import 'package:shiroha_quiz/application/agent/agent_config_service.dart';
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/data/persistence/ai_engine_store.dart';
import 'package:shiroha_quiz/data/repositories/agent_profile_repository.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';
import 'package:shiroha_quiz/ui/pages/agent_settings_screen.dart';

import '../../support/memory_engine_credential_store.dart';

void main() {
  Future<void> pumpSettings(
    WidgetTester tester,
    AgentSettingsService service, {
    VoidCallback? onOpenProfiles,
  }) async {
    tester.view.physicalSize = const Size(800, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: AgentSettingsScreen(
          settingsService: service,
          onOpenProfileSettings: onOpenProfiles,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'selects profile and saves Agent tuning without mutating Parsing profile',
    (tester) async {
      final parsingStore = _ParsingEngineStore();
      final engineRepository = AiEngineRepository(
        store: parsingStore,
        credentialStore: MemoryEngineCredentialStore({
          'profile-a': 'secret-a',
          'profile-b': 'secret-b',
        }),
      );
      final configStore = _ConfigStore(
        encoded: const AgentConfigCodec().encode(
          AgentConfig(
            providerKind: AgentProviderKind.deepSeekResponses,
            mainProfileId: 'profile-a',
          ),
        ),
      );
      final service = AgentSettingsService(
        configStore: configStore,
        profileCatalog: AiEngineAgentProfileRepository(
          engineRepository: engineRepository,
        ),
      );
      final parsingBefore = parsingStore.profiles['profile-a']!;

      await pumpSettings(tester, service);
      expect(find.text('Shiroha Agent 设置'), findsOneWidget);
      expect(find.textContaining('Alpha · deepseek-v4-flash'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('a0-agent-main-profile')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Beta · other-model').last);
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey<String>('a0-agent-web-toggle')),
      );
      final slider = tester.widget<Slider>(
        find.byKey(const ValueKey<String>('a0-agent-temperature')),
      );
      slider.onChanged!(1.4);
      await tester.pump();
      await tester.tap(find.text('最高'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey<String>('a0-agent-save')));
      await tester.pumpAndSettle();

      final saved = const AgentConfigCodec().decode(configStore.encoded!);
      expect(saved.mainProfileId, 'profile-b');
      expect(saved.webEnabled, isTrue);
      expect(saved.temperature, closeTo(1.4, 0.001));
      expect(saved.reasoningEffort, AgentReasoningEffort.max);

      expect(parsingStore.activeTextId, 'profile-a');
      expect(parsingStore.profiles['profile-a'], same(parsingBefore));
      expect(parsingBefore.temperature, 0.3);
      expect(parsingBefore.reasoningEffort, 'parsing-only');
    },
  );

  testWidgets('shows profile-unavailable state and permits a valid reselection',
      (tester) async {
    final store = _ConfigStore(
      encoded: const AgentConfigCodec().encode(
        AgentConfig(
          providerKind: AgentProviderKind.deepSeekResponses,
          mainProfileId: 'missing-profile',
          webEnabled: true,
          temperature: 1.6,
          reasoningEffort: AgentReasoningEffort.max,
        ),
      ),
    );
    final service = AgentSettingsService(
      configStore: store,
      profileCatalog: _Catalog(
        <AgentProfileSummary>[
          AgentProfileSummary(
            profileId: 'profile-ok',
            displayName: '可用模型',
            modelName: 'deepseek-v4-flash',
          ),
        ],
      ),
    );
    await pumpSettings(tester, service);

    expect(
      find.byKey(const ValueKey<String>('a0-agent-profile-unavailable')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('a0-agent-main-profile')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('可用模型').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('a0-agent-save')));
    await tester.pumpAndSettle();

    expect(const AgentConfigCodec().decode(store.encoded!).mainProfileId,
        'profile-ok');
  });

  testWidgets('empty and failure states stay safe and actionable',
      (tester) async {
    var openedProfiles = false;
    final emptyService = AgentSettingsService(
      configStore: _ConfigStore(),
      profileCatalog: _Catalog(const <AgentProfileSummary>[]),
    );
    await pumpSettings(
      tester,
      emptyService,
      onOpenProfiles: () => openedProfiles = true,
    );
    expect(find.text('暂无可用于 Shiroha Agent 的文本模型配置'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('a0-agent-open-ai-profiles')),
    );
    expect(openedProfiles, isTrue);

    await tester.pumpWidget(
      MaterialApp(
        home: AgentSettingsScreen(
          key: const ValueKey<String>('failing-agent-settings'),
          settingsService: AgentSettingsService(
            configStore: _ConfigStore(failReads: true),
            profileCatalog: _Catalog(const <AgentProfileSummary>[]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('暂时无法保存设置，请稍后重试'), findsOneWidget);
    expect(find.textContaining('AgentConfigStoreException'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('a0-agent-settings-retry')),
      findsOneWidget,
    );
  });

  testWidgets('selects and saves optional fallback profile', (tester) async {
    final store = _ConfigStore(
      encoded: const AgentConfigCodec().encode(
        AgentConfig(
          providerKind: AgentProviderKind.deepSeekResponses,
          mainProfileId: 'profile-a',
        ),
      ),
    );
    final catalog = _Catalog(<AgentProfileSummary>[
      AgentProfileSummary(
        profileId: 'profile-a',
        displayName: 'Alpha',
        modelName: 'deepseek-v4-flash',
      ),
      AgentProfileSummary(
        profileId: 'profile-b',
        displayName: 'Beta',
        modelName: 'other-model',
      ),
    ]);
    final service = AgentSettingsService(
      configStore: store,
      profileCatalog: catalog,
    );
    await pumpSettings(tester, service);

    expect(find.textContaining('备用模型（可选）'), findsOneWidget);
    expect(
      find.text('主模型在回复或工具调用前发生可恢复故障时，Shiroha 最多自动尝试一次备用模型。含文件正文授权的对话不会自动切换。'),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('a0-agent-fallback-profile')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Beta · other-model').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('a0-agent-save')));
    await tester.pumpAndSettle();

    final saved = const AgentConfigCodec().decode(store.encoded!);
    expect(saved.mainProfileId, 'profile-a');
    expect(saved.fallbackProfileId, 'profile-b');
  });

  testWidgets('shows fallback-unavailable notice and permits clearing fallback',
      (tester) async {
    final store = _ConfigStore(
      encoded: const AgentConfigCodec().encode(
        AgentConfig(
          providerKind: AgentProviderKind.deepSeekResponses,
          mainProfileId: 'profile-a',
          fallbackProfileId: 'deleted-profile',
        ),
      ),
    );
    final catalog = _Catalog(<AgentProfileSummary>[
      AgentProfileSummary(
        profileId: 'profile-a',
        displayName: 'Alpha',
        modelName: 'deepseek-v4-flash',
      ),
    ]);
    final service = AgentSettingsService(
      configStore: store,
      profileCatalog: catalog,
    );
    await pumpSettings(tester, service);

    expect(
      find.byKey(const ValueKey<String>('a0-agent-fallback-unavailable')),
      findsOneWidget,
    );

    // Save with '不使用备用模型' (which is default when fallback is missing)
    await tester.tap(find.byKey(const ValueKey<String>('a0-agent-save')));
    await tester.pumpAndSettle();

    final saved = const AgentConfigCodec().decode(store.encoded!);
    expect(saved.mainProfileId, 'profile-a');
    expect(saved.fallbackProfileId, isNull);
  });
}

final class _ConfigStore implements AgentConfigStorePort {
  _ConfigStore({this.encoded, this.failReads = false});

  String? encoded;
  final bool failReads;

  @override
  Future<String?> readAgentConfig() async {
    if (failReads) {
      throw const AgentConfigStoreException(
        AgentConfigStoreFailure.temporarilyUnavailable,
      );
    }
    return encoded;
  }

  @override
  Future<void> writeAgentConfig(String encodedConfig) async {
    encoded = encodedConfig;
  }
}

final class _Catalog implements AgentProfileCatalogPort {
  const _Catalog(this.profiles);

  final List<AgentProfileSummary> profiles;

  @override
  Future<List<AgentProfileSummary>> listMainProfiles() async => profiles;
}

final class _ParsingEngineStore implements AiEngineStore {
  final Map<String, AiEngineProfile> profiles = <String, AiEngineProfile>{
    'profile-a': const AiEngineProfile(
      id: 'profile-a',
      engineType: AiEngineType.text,
      name: 'Alpha',
      apiKey: 'secret-a',
      baseUrl: 'https://example.invalid',
      modelName: 'deepseek-v4-flash',
      temperature: 0.3,
      reasoningEffort: 'parsing-only',
      isActive: true,
    ),
    'profile-b': const AiEngineProfile(
      id: 'profile-b',
      engineType: AiEngineType.text,
      name: 'Beta',
      apiKey: 'secret-b',
      baseUrl: 'https://example.invalid',
      modelName: 'other-model',
      temperature: 0.8,
      reasoningEffort: '',
      isActive: false,
    ),
  };
  String activeTextId = 'profile-a';

  @override
  Future<void> deleteAiEngine(String id) async => profiles.remove(id);

  @override
  Future<AiEngineProfile?> getActiveAiEngine(AiEngineType type) async =>
      type == AiEngineType.text ? profiles[activeTextId] : null;

  @override
  Future<List<AiEngineProfile>> listAiEngines(AiEngineType type) async =>
      type == AiEngineType.text ? profiles.values.toList() : const [];

  @override
  Future<void> saveAiEngine(AiEngineProfile profile) async {
    profiles[profile.id] = profile;
  }

  @override
  Future<void> setActiveAiEngine(String id, AiEngineType type) async {
    if (type == AiEngineType.text) activeTextId = id;
  }
}
