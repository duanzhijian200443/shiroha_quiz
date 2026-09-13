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

  test('maps Minimal v2 semantic colors in light and dark themes', () {
    _verifySemanticPalette(AppTheme.lightTheme);
    _verifySemanticPalette(AppTheme.darkTheme);
  });

  Future<void> pumpProfile(
    WidgetTester tester, {
    Size size = const Size(390, 1200),
    TextScaler textScaler = TextScaler.noScaling,
    ThemeData? theme,
    Map<DateTime, int> heatmap = const {},
    ProfileHeatmapLoader? heatmapLoader,
    VoidCallback? onOpenFileLibrary,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: theme ?? AppTheme.lightTheme,
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
          heatmapLoader: heatmapLoader ?? () async => heatmap,
          onOpenFileLibrary: onOpenFileLibrary,
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
    expect(find.text('累计完成 0 题 · 学习 0 天'), findsOneWidget);
    expect(find.text('最近 12 周学习记录'), findsOneWidget);
    expect(find.text('学习记录'), findsOneWidget);
    expect(find.text('错题记录'), findsOneWidget);
    expect(find.text('AI 与知识库'), findsOneWidget);
    expect(find.text('资料库'), findsOneWidget);
    expect(find.text('AI 服务'), findsOneWidget);
    expect(find.text('Shiroha Agent 设置'), findsNothing);
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

  testWidgets('AI service aggregates the three existing provider routes', (
    tester,
  ) async {
    await pumpProfile(tester);

    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('profile-ai-service-row')),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('profile-ai-service-row')),
    );
    await tester.pumpAndSettle();

    expect(find.text('AI 服务'), findsOneWidget);
    expect(find.text('能力配置'), findsOneWidget);
    expect(find.text('文本模型'), findsOneWidget);
    expect(find.text('图片理解'), findsOneWidget);
    expect(find.text('文档识别'), findsOneWidget);
    expect(find.text('Agent'), findsOneWidget);
    expect(find.text('Shiroha Agent 设置'), findsOneWidget);
    expect(find.text('DeepSeek'), findsOneWidget);
    expect(find.text('智谱视觉'), findsOneWidget);
    expect(find.text('智谱 OCR'), findsOneWidget);
    expect(find.text('文本与逻辑中枢'), findsNothing);
    expect(find.text('视觉与多模态矩阵'), findsNothing);
    expect(find.text('文档 OCR 解析引擎'), findsNothing);
  });

  testWidgets('AI service isolates one failed summary and keeps every entry', (
    tester,
  ) async {
    final store = _ProfileAiEngineStore()
      ..failedActiveTypes.add(AiEngineType.vision);
    engineRepository = AiEngineRepository(
      store: store,
      credentialStore: MemoryEngineCredentialStore(),
    );
    await pumpProfile(tester);

    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('profile-ai-service-row')),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('profile-ai-service-row')),
    );
    await tester.pumpAndSettle();

    expect(find.text('暂时无法读取 · 点击配置'), findsOneWidget);
    expect(find.textContaining('PRIVATE_AI_FAILURE'), findsNothing);
    expect(find.text('DeepSeek'), findsOneWidget);
    expect(find.text('智谱 OCR'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('ai-service-vision-row')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<ListTile>(
            find.descendant(
              of: find.byKey(
                const ValueKey<String>('ai-service-vision-row'),
              ),
              matching: find.byType(ListTile),
            ),
          )
          .onTap,
      isNotNull,
    );
    expect(find.text('Shiroha Agent 设置'), findsOneWidget);
  });

  testWidgets('shows total learning days from real heatmap activity', (
    tester,
  ) async {
    await pumpProfile(
      tester,
      heatmap: <DateTime, int>{
        DateTime(2026, 8, 30): 2,
        DateTime(2026, 8, 31): 3,
        DateTime(2026, 8, 29): 0,
      },
    );

    expect(find.text('累计完成 5 题 · 学习 2 天'), findsOneWidget);
  });

  testWidgets('load failure shows a safe retry state instead of false zeros', (
    tester,
  ) async {
    var shouldFail = true;
    await pumpProfile(
      tester,
      heatmapLoader: () async {
        if (shouldFail) throw StateError('PRIVATE_PROFILE_FAILURE');
        return <DateTime, int>{DateTime(2026, 8, 31): 3};
      },
    );

    expect(find.text('暂时无法读取学习记录'), findsOneWidget);
    expect(find.textContaining('PRIVATE_PROFILE_FAILURE'), findsNothing);
    expect(find.textContaining('累计完成 0 题'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('profile-ai-service-row')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('profile-file-library-row')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('profile-appearance-row')),
      findsOneWidget,
    );

    shouldFail = false;
    await tester.tap(
      find.byKey(const ValueKey<String>('profile-load-retry')),
    );
    await tester.pumpAndSettle();

    expect(find.text('累计完成 3 题 · 学习 1 天'), findsOneWidget);
    expect(find.text('暂时无法读取学习记录'), findsNothing);
  });

  testWidgets('opens the shared File Library shortcut authority', (
    tester,
  ) async {
    var opened = false;
    await pumpProfile(tester, onOpenFileLibrary: () => opened = true);

    final shortcut = find.byKey(
      const ValueKey<String>('profile-file-library-row'),
    );
    await tester.ensureVisible(shortcut);
    await tester.tap(shortcut);

    expect(opened, isTrue);
    expect(find.text('我的知识库'), findsNothing);
  });

  testWidgets(
    'uses one profile structure with semantic accents in both themes',
    (tester) async {
      for (final theme in <ThemeData>[
        AppTheme.lightTheme,
        AppTheme.darkTheme,
      ]) {
        await pumpProfile(tester, theme: theme);

        final aiRow = find.byKey(
          const ValueKey<String>('profile-ai-service-row'),
        );
        final libraryRow = find.byKey(
          const ValueKey<String>('profile-file-library-row'),
        );
        await tester.ensureVisible(libraryRow);

        final aiIcon = tester.widget<Icon>(
          find.descendant(
            of: aiRow,
            matching: find.byIcon(Icons.auto_awesome_outlined),
          ),
        );
        final libraryIcon = tester.widget<Icon>(
          find.descendant(
            of: libraryRow,
            matching: find.byIcon(Icons.auto_stories_outlined),
          ),
        );

        expect(aiIcon.color, theme.colorScheme.secondary);
        expect(libraryIcon.color, theme.colorScheme.primary);
        expect(find.text('学习记录'), findsOneWidget);
        expect(find.text('AI 与知识库'), findsOneWidget);
        expect(find.text('设置与数据'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets('supports a narrow window and enlarged system text', (
    tester,
  ) async {
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

void _verifySemanticPalette(ThemeData theme) {
  expect(theme.colorScheme.primary, AppTheme.shirohaCyan);
  expect(theme.colorScheme.secondary, AppTheme.irisPurple);
  expect(theme.colorScheme.tertiary, AppTheme.warningAmber);
  expect(theme.colorScheme.error, AppTheme.dangerRed);
  if (theme.brightness == Brightness.light) {
    expect(
      _contrastRatio(theme.colorScheme.primary, theme.colorScheme.onPrimary),
      greaterThanOrEqualTo(4.5),
    );
    expect(
      _contrastRatio(
        theme.colorScheme.secondary,
        theme.colorScheme.onSecondary,
      ),
      greaterThanOrEqualTo(4.5),
    );
    expect(
      _contrastRatio(theme.colorScheme.error, theme.colorScheme.onError),
      greaterThanOrEqualTo(4.5),
    );
    expect(
      _contrastRatio(
        theme.colorScheme.onSurfaceVariant,
        theme.colorScheme.surface,
      ),
      greaterThanOrEqualTo(4.5),
    );
    expect(
      _contrastRatio(
        theme.colorScheme.onSurfaceVariant,
        theme.scaffoldBackgroundColor,
      ),
      greaterThanOrEqualTo(4.5),
    );
    expect(
      _contrastRatio(
        theme.bottomNavigationBarTheme.selectedItemColor!,
        theme.colorScheme.surface,
      ),
      greaterThanOrEqualTo(4.5),
    );
  }
}

double _contrastRatio(Color first, Color second) {
  final firstLuminance = first.computeLuminance();
  final secondLuminance = second.computeLuminance();
  final lighter =
      firstLuminance > secondLuminance ? firstLuminance : secondLuminance;
  final darker =
      firstLuminance > secondLuminance ? secondLuminance : firstLuminance;
  return (lighter + 0.05) / (darker + 0.05);
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
  final Set<AiEngineType> failedActiveTypes = <AiEngineType>{};

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
  Future<AiEngineProfile?> getActiveAiEngine(AiEngineType type) async {
    if (failedActiveTypes.contains(type)) {
      throw StateError('PRIVATE_AI_FAILURE');
    }
    return _profiles[type];
  }

  @override
  Future<List<AiEngineProfile>> listAiEngines(AiEngineType type) async =>
      <AiEngineProfile>[_profiles[type]!];

  @override
  Future<void> saveAiEngine(AiEngineProfile profile) async {}

  @override
  Future<void> setActiveAiEngine(String id, AiEngineType type) async {}
}
