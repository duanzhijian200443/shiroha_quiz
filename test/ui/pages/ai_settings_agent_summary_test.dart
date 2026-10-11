import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/agent/agent_config.dart';
import 'package:shiroha_quiz/application/agent/agent_config_service.dart';
import 'package:shiroha_quiz/application/ai_config/ai_config_service.dart';
import 'package:shiroha_quiz/domain/ai_config/ai_config_contracts.dart';
import 'package:shiroha_quiz/ui/pages/agent_settings_screen.dart';
import 'package:shiroha_quiz/ui/pages/ai_settings_screen.dart';
import 'package:shiroha_quiz/ui/theme/app_theme.dart';

const Key _agentRowKey = ValueKey<String>('ai-service-agent-settings-row');

AgentProfileSummary _profile(String profileId, String displayName) =>
    AgentProfileSummary(
      profileId: profileId,
      displayName: displayName,
      modelName: 'model-$profileId',
    );

String _encodeConfig(String mainProfileId) => const AgentConfigCodec().encode(
      AgentConfig(
        providerKind: AgentProviderKind.deepSeekResponses,
        mainProfileId: mainProfileId,
      ),
    );

Future<void> _pumpHub(
  WidgetTester tester, {
  required AgentSettingsService agentService,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.lightTheme,
      home: AiSettingsScreen(
        configService: _UiAiConfigService(),
        agentSettingsService: agentService,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Agent summary reads the configured main model name', (
    tester,
  ) async {
    final store = _ConfigStore(encoded: _encodeConfig('profile-a'));
    final service = AgentSettingsService(
      configStore: store,
      profileCatalog: _Catalog(<AgentProfileSummary>[
        _profile('profile-a', 'Alpha'),
      ]),
    );
    await _pumpHub(tester, agentService: service);

    expect(
      find.descendant(
          of: find.byKey(_agentRowKey), matching: find.text('Alpha')),
      findsOneWidget,
    );
  });

  testWidgets('Agent summary shows the unconfigured placeholder', (
    tester,
  ) async {
    final service = AgentSettingsService(
      configStore: _ConfigStore(),
      profileCatalog: _Catalog(<AgentProfileSummary>[
        _profile('profile-a', 'Alpha'),
      ]),
    );
    await _pumpHub(tester, agentService: service);

    expect(
      find.descendant(
        of: find.byKey(_agentRowKey),
        matching: find.text('尚未配置主模型'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('Agent summary reports an unavailable selected profile honestly',
      (
    tester,
  ) async {
    final service = AgentSettingsService(
      configStore: _ConfigStore(encoded: _encodeConfig('deleted-profile')),
      profileCatalog: _Catalog(<AgentProfileSummary>[
        _profile('profile-a', 'Alpha'),
      ]),
    );
    await _pumpHub(tester, agentService: service);

    expect(
      find.descendant(
        of: find.byKey(_agentRowKey),
        matching: find.text('所选模型配置已不可用'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('Agent summary degrades honestly when the read fails', (
    tester,
  ) async {
    final service = AgentSettingsService(
      configStore: _ConfigStore(failReads: true),
      profileCatalog: _Catalog(<AgentProfileSummary>[
        _profile('profile-a', 'Alpha'),
      ]),
    );
    await _pumpHub(tester, agentService: service);

    expect(
      find.descendant(
        of: find.byKey(_agentRowKey),
        matching: find.text('暂时无法读取 · 点击选择'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('returning from Agent settings refreshes the summary', (
    tester,
  ) async {
    final store = _ConfigStore();
    final service = AgentSettingsService(
      configStore: store,
      profileCatalog: _Catalog(<AgentProfileSummary>[
        _profile('profile-a', 'Alpha'),
      ]),
    );
    await _pumpHub(tester, agentService: service);
    expect(
      find.descendant(
        of: find.byKey(_agentRowKey),
        matching: find.text('尚未配置主模型'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(_agentRowKey));
    await tester.pumpAndSettle();
    expect(find.byType(AgentSettingsScreen), findsOneWidget);

    // A save performed inside the Agent settings page lands in the store.
    store.encoded = _encodeConfig('profile-a');
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(
      find.descendant(
          of: find.byKey(_agentRowKey), matching: find.text('Alpha')),
      findsOneWidget,
    );
    expect(find.text('尚未配置主模型'), findsNothing);
  });

  testWidgets('a stale Agent summary completion never overwrites a newer one', (
    tester,
  ) async {
    final store = _ConfigStore()..stallFirstRead = true;
    final service = AgentSettingsService(
      configStore: store,
      profileCatalog: _Catalog(<AgentProfileSummary>[
        _profile('profile-a', 'Alpha'),
      ]),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: AiSettingsScreen(
          configService: _UiAiConfigService(),
          agentSettingsService: service,
        ),
      ),
    );
    await tester.pump();

    // The initial read is still in flight while the store already changed.
    expect(find.text('正在读取…'), findsOneWidget);
    store.encoded = _encodeConfig('profile-a');

    // Leaving the model selector refreshes the hub: the newer request wins.
    await tester.tap(find.byKey(const ValueKey<String>('ai-service-text-row')));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(
      find.descendant(
          of: find.byKey(_agentRowKey), matching: find.text('Alpha')),
      findsOneWidget,
    );

    // The stale first request completes last and must be discarded.
    store.firstReadCompleter!.complete(null);
    await tester.pumpAndSettle();
    expect(
      find.descendant(
          of: find.byKey(_agentRowKey), matching: find.text('Alpha')),
      findsOneWidget,
    );
    expect(find.text('尚未配置主模型'), findsNothing);
  });
}

final class _ConfigStore implements AgentConfigStorePort {
  _ConfigStore({this.encoded, this.failReads = false});

  String? encoded;
  bool failReads;
  bool stallFirstRead = false;
  int reads = 0;
  Completer<String?>? firstReadCompleter;

  @override
  Future<String?> readAgentConfig() {
    reads++;
    if (stallFirstRead && reads == 1) {
      final completer = Completer<String?>();
      firstReadCompleter = completer;
      return completer.future;
    }
    if (failReads) {
      throw const AgentConfigStoreException(
        AgentConfigStoreFailure.temporarilyUnavailable,
      );
    }
    return Future<String?>.value(encoded);
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

final class _UiAiConfigService implements AiConfigPresentationService {
  @override
  Future<AiCapabilityBindingSummary?> bindingSummary(
    AiCapabilitySlot slot,
  ) async =>
      null;

  @override
  Future<List<AiModelCompatibility>> listModelsForSlot(
    AiCapabilitySlot slot,
  ) async =>
      const <AiModelCompatibility>[];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
