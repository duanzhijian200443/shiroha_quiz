import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/agent/agent_config_service.dart';
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/data/persistence/ai_engine_store.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';
import 'package:shiroha_quiz/ui/pages/profile_screen.dart';
import 'package:shiroha_quiz/ui/theme/app_theme.dart';

import 'support/memory_engine_credential_store.dart';

void main() {
  late AiEngineRepository engineRepository;

  setUp(() {
    engineRepository = AiEngineRepository(
      store: _ProfileAiEngineStore(),
      credentialStore: MemoryEngineCredentialStore(),
    );
  });

  Future<void> pumpProfile(
    WidgetTester tester, {
    Size size = const Size(390, 1200),
    TextScaler textScaler = TextScaler.noScaling,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: child!,
        ),
        home: ProfileScreen(
          engineRepository: engineRepository,
          agentSettingsService: AgentSettingsService(
            configStore: _ProfileAgentConfigStore(),
            profileCatalog: _ProfileAgentCatalog(),
          ),
          heatmapLoader: () async => <DateTime, int>{},
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('presents a user-facing personal center', (tester) async {
    await pumpProfile(tester);

    expect(find.text('我的'), findsOneWidget);
    expect(find.text('我的控制台'), findsNothing);
    expect(find.text('Shiroha 学员'), findsOneWidget);
    expect(find.text('累计完成 0 道题'), findsOneWidget);
    expect(find.text('最近 12 周学习记录'), findsOneWidget);
    expect(find.text('学习记录'), findsOneWidget);
    expect(find.text('错题记录'), findsOneWidget);
    expect(find.text('AI 与知识库'), findsOneWidget);
    expect(find.text('我的知识库'), findsOneWidget);
    expect(find.text('AI 服务'), findsOneWidget);
    expect(find.text('Shiroha Agent 设置'), findsOneWidget);
    expect(find.text('设置与数据'), findsOneWidget);
    expect(find.text('外观设置'), findsOneWidget);

    for (final technicalCopy in <String>[
      '知识引擎',
      'AI 分布式核心配置',
      '文本与逻辑中枢',
      '视觉与多模态矩阵',
      '文档 OCR 解析引擎',
      '界面皮肤引擎',
    ]) {
      expect(find.text(technicalCopy), findsNothing);
    }

    final heatmapCell = find.byKey(
      const ValueKey<String>('profile-heatmap-cell-0-0'),
    );
    expect(tester.getSize(heatmapCell), const Size.square(10));
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI service aggregates the three existing provider routes',
      (tester) async {
    await pumpProfile(tester);

    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('profile-ai-service-row')),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('profile-ai-service-row')),
    );
    await tester.pumpAndSettle();

    expect(find.text('AI 服务'), findsOneWidget);
    expect(find.text('文本解答模型'), findsOneWidget);
    expect(find.text('图片理解模型'), findsOneWidget);
    expect(find.text('文档识别服务'), findsOneWidget);
    expect(find.text('DeepSeek'), findsOneWidget);
    expect(find.text('智谱视觉'), findsOneWidget);
    expect(find.text('智谱 OCR'), findsOneWidget);
    expect(find.text('文本与逻辑中枢'), findsNothing);
    expect(find.text('视觉与多模态矩阵'), findsNothing);
    expect(find.text('文档 OCR 解析引擎'), findsNothing);
  });

  testWidgets('supports a narrow window and enlarged system text',
      (tester) async {
    await pumpProfile(
      tester,
      size: const Size(360, 1500),
      textScaler: const TextScaler.linear(1.3),
    );

    await tester.scrollUntilVisible(
      find.text('外观设置'),
      300,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.text('外观设置'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

final class _ProfileAgentConfigStore implements AgentConfigStorePort {
  @override
  Future<String?> readAgentConfig() async => null;

  @override
  Future<void> writeAgentConfig(String encodedConfig) async {}
}

final class _ProfileAgentCatalog implements AgentProfileCatalogPort {
  @override
  Future<List<AgentProfileSummary>> listMainProfiles() async => const [];
}

class _ProfileAiEngineStore implements AiEngineStore {
  static const Map<AiEngineType, AiEngineProfile> _profiles = {
    AiEngineType.text: AiEngineProfile(
      id: 'text',
      engineType: AiEngineType.text,
      name: 'DeepSeek',
      apiKey: '',
      baseUrl: 'https://example.invalid',
      modelName: 'text-model',
      temperature: 0.7,
      reasoningEffort: '',
      isActive: true,
    ),
    AiEngineType.vision: AiEngineProfile(
      id: 'vision',
      engineType: AiEngineType.vision,
      name: '智谱视觉',
      apiKey: '',
      baseUrl: 'https://example.invalid',
      modelName: 'vision-model',
      temperature: 0.7,
      reasoningEffort: '',
      isActive: true,
    ),
    AiEngineType.ocr: AiEngineProfile(
      id: 'ocr',
      engineType: AiEngineType.ocr,
      name: '智谱 OCR',
      apiKey: '',
      baseUrl: 'https://example.invalid',
      modelName: 'ocr-model',
      temperature: 0.7,
      reasoningEffort: '',
      isActive: true,
    ),
  };

  @override
  Future<void> deleteAiEngine(String id) async {}

  @override
  Future<AiEngineProfile?> getActiveAiEngine(AiEngineType type) async =>
      _profiles[type];

  @override
  Future<List<AiEngineProfile>> listAiEngines(AiEngineType type) async =>
      <AiEngineProfile>[_profiles[type]!];

  @override
  Future<void> saveAiEngine(AiEngineProfile profile) async {}

  @override
  Future<void> setActiveAiEngine(String id, AiEngineType type) async {}
}
