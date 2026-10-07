import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/agent/agent_config_service.dart';
import 'package:shiroha_quiz/application/ai_config/ai_config_service.dart';
import 'package:shiroha_quiz/domain/ai_config/ai_config_contracts.dart';
import 'package:shiroha_quiz/ui/pages/profile_screen.dart';
import 'package:shiroha_quiz/ui/theme/app_theme.dart';
import 'package:shiroha_quiz/ui/theme/shiroha_theme_tokens.dart';
import 'package:shiroha_quiz/data/repositories/settings_repository.dart';
import 'package:shiroha_quiz/main.dart' show globalThemeNotifier;
import 'support/theme_visual_evidence.dart';

void main() {
  final visualKey = GlobalKey();
  setUpAll(loadThemeEvidenceFonts);
  setUp(() => globalThemeNotifier.value = 'light');
  tearDown(() => globalThemeNotifier.value = 'light');
  test('maps shared semantic colors in all three appearances', () {
    _verifySemanticPalette(AppTheme.lightTheme);
    _verifySemanticPalette(AppTheme.darkTheme);
    _verifySemanticPalette(AppTheme.colorfulTheme);
  });

  Future<void> pumpProfile(
    WidgetTester tester, {
    Size size = const Size(390, 1200),
    TextScaler textScaler = TextScaler.noScaling,
    ThemeData? theme,
    Map<DateTime, int> heatmap = const {},
    ProfileHeatmapLoader? heatmapLoader,
    VoidCallback? onOpenFileLibrary,
    AiConfigPresentationService? aiConfigService,
    SettingsRepository? appearanceSettings,
    bool followGlobal = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Widget buildApp(ThemeData activeTheme) => MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: themeEvidenceEnabled
              ? activeTheme.copyWith(
                  appBarTheme: activeTheme.appBarTheme.copyWith(
                      titleTextStyle: activeTheme.appBarTheme.titleTextStyle
                          ?.copyWith(fontFamily: 'Roboto')))
              : activeTheme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: textScaler),
            child: child!,
          ),
          home: ProfileScreen(
            aiConfigService: aiConfigService ?? _ProfileAiConfigService(),
            agentSettingsService: AgentSettingsService(
              configStore: _ProfileAgentConfigStore(),
              profileCatalog: _ProfileAgentCatalog(),
            ),
            heatmapLoader: heatmapLoader ?? () async => heatmap,
            onOpenFileLibrary: onOpenFileLibrary,
            appearanceSettings: appearanceSettings,
          ),
        );
    final app = followGlobal
        ? ValueListenableBuilder<String>(
            valueListenable: globalThemeNotifier,
            builder: (_, value, __) => buildApp(AppTheme.getTheme(value)),
          )
        : buildApp(theme ?? AppTheme.lightTheme);
    await tester.pumpWidget(RepaintBoundary(key: visualKey, child: app));
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
    await pumpProfile(
      tester,
      aiConfigService: _ProfileAiConfigService(
        failedSlots: <AiCapabilitySlot>{
          AiCapabilitySlot.imageUnderstanding,
        },
      ),
    );

    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('profile-ai-service-row')),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('profile-ai-service-row')),
    );
    await tester.pumpAndSettle();

    expect(find.text('暂时无法读取 · 点击选择'), findsOneWidget);
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
        AppTheme.colorfulTheme,
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
        final tokens = theme.extension<ShirohaThemeTokens>()!;
        expect(libraryIcon.color, tokens.featureLibrary);
        final avatar = tester.widget<CircleAvatar>(find.byType(CircleAvatar));
        expect(avatar.backgroundColor, tokens.brandFill);
        expect((avatar.child! as Icon).color, tokens.brandAccent);
        for (final entry in [
          ('profile-ai-service-row', tokens.featureAiFill),
          ('profile-file-library-row', tokens.featureLibraryFill),
          ('profile-wrong-book-row', tokens.featureNeutralFill),
        ]) {
          final row = tester.widget<ListTile>(find.descendant(
              of: find.byKey(ValueKey(entry.$1)),
              matching: find.byType(ListTile)));
          final base = row.leading! as Container;
          expect(base.constraints!.maxWidth, 38);
          expect(base.constraints!.maxHeight, 38);
          expect((base.decoration! as BoxDecoration).color, entry.$2);
          expect((base.child! as Icon).size, 21);
        }
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

  testWidgets(
      'three exclusive options preview immediately and save each choice',
      (tester) async {
    final settings = _AppearanceSettings();
    await pumpProfile(tester, appearanceSettings: settings, followGlobal: true);
    await tester
        .ensureVisible(find.byKey(const ValueKey('profile-appearance-row')));
    await tester.tap(find.byKey(const ValueKey('profile-appearance-row')));
    await tester.pumpAndSettle();
    for (final name in ['colorful', 'dark', 'light']) {
      await tester.tap(find.byKey(ValueKey('appearance-option-$name')));
      await tester.pumpAndSettle();
      expect(globalThemeNotifier.value, name);
      expect(settings.saved, name);
      final selected = tester
          .widget<ListTile>(find.byKey(ValueKey('appearance-option-$name')));
      expect(selected.selected, isTrue);
      expect(
          tester
              .widgetList<ListTile>(
                  find.byKey(const ValueKey('appearance-option-light')))
              .length,
          1);
      final actualTheme = Theme.of(
          tester.element(find.byKey(ValueKey('appearance-option-$name'))));
      expect(
          actualTheme.extension<ShirohaThemeTokens>()!.appearance.name, name);
      for (final other
          in ['light', 'dark', 'colorful'].where((v) => v != name)) {
        expect(
            tester
                .widget<ListTile>(
                    find.byKey(ValueKey('appearance-option-$other')))
                .selected,
            isFalse);
      }
    }
    expect(settings.calls, 3);
    expect(tester.takeException(), isNull);
  });

  for (final appearance in ['light', 'dark', 'colorful']) {
    for (final populated in [false, true]) {
      testWidgets('profile polish sample $appearance populated=$populated',
          (tester) async {
        globalThemeNotifier.value = appearance;
        final now = DateTime.now();
        final today = DateTime(now.year, now.month, now.day);
        final heatmap = populated
            ? <DateTime, int>{
                today: 80,
                today.subtract(const Duration(days: 1)): 42,
                today.subtract(const Duration(days: 2)): 18,
                today.subtract(const Duration(days: 3)): 4,
              }
            : <DateTime, int>{};
        await pumpProfile(tester,
            theme: AppTheme.getTheme(appearance), heatmap: heatmap);
        await captureThemeEvidence(tester, visualKey,
            'profile-${populated ? 'records' : 'empty'}-$appearance');
        expect(
            find.text(populated ? '累计完成 144 题 · 学习 4 天' : '累计完成 0 题 · 学习 0 天'),
            findsOneWidget);
        final cells = tester.widgetList<Container>(find.byWidgetPredicate(
            (widget) =>
                widget is Container &&
                widget.key is ValueKey<String> &&
                (widget.key! as ValueKey<String>)
                    .value
                    .startsWith('profile-heatmap-cell-')));
        expect(cells.length, 84);
        final shades = cells
            .map((cell) => (cell.decoration! as BoxDecoration).color!)
            .toSet();
        expect(shades.length, populated ? 5 : 1);
        expect(
            find.descendant(
                of: find.byKey(const ValueKey('profile-appearance-row')),
                matching: find.text({
                  'light': '浅色',
                  'dark': '深色',
                  'colorful': '彩色'
                }[appearance]!)),
            findsOneWidget);
        if (populated) {
          final levels = <double>[];
          for (var day = 2; day < 7; day++) {
            final cell = tester.widget<Container>(
                find.byKey(ValueKey('profile-heatmap-cell-11-$day')));
            levels.add(
                (cell.decoration! as BoxDecoration).color!.computeLuminance());
          }
          for (var level = 1; level < levels.length; level++) {
            expect(
                levels[level],
                appearance == 'dark'
                    ? greaterThan(levels[level - 1])
                    : lessThan(levels[level - 1]));
          }
        }
        expect(tester.takeException(), isNull);
      });
    }
    testWidgets('appearance sample screenshots: $appearance', (tester) async {
      globalThemeNotifier.value = appearance;
      await pumpProfile(tester,
          followGlobal: true, appearanceSettings: _AppearanceSettings());
      await captureThemeEvidence(tester, visualKey, 'profile-$appearance');
      await tester
          .ensureVisible(find.byKey(const ValueKey('profile-ai-service-row')));
      await tester.tap(find.byKey(const ValueKey('profile-ai-service-row')));
      await tester.pumpAndSettle();
      await captureThemeEvidence(tester, visualKey, 'ai-service-$appearance');
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester
          .ensureVisible(find.byKey(const ValueKey('profile-appearance-row')));
      await tester.tap(find.byKey(const ValueKey('profile-appearance-row')));
      await tester.pumpAndSettle();
      await captureThemeEvidence(tester, visualKey, 'appearance-$appearance');
      expect(
          tester
              .widget<ListTile>(
                  find.byKey(ValueKey('appearance-option-$appearance')))
              .selected,
          isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  for (final appearance in ['light', 'dark', 'colorful']) {
    for (final width in [320.0, 1100.0]) {
      for (final scale in [1.0, 1.8]) {
        testWidgets(
            'profile polish responsive $appearance width=$width scale=$scale',
            (tester) async {
          globalThemeNotifier.value = appearance;
          await pumpProfile(tester,
              theme: AppTheme.getTheme(appearance),
              size: Size(width, 1500),
              textScaler: TextScaler.linear(scale));
          await tester.scrollUntilVisible(find.text('外观设置'), 250,
              scrollable: find.byType(Scrollable).first);
          expect(find.text('资料库'), findsOneWidget);
          expect(find.text('外观设置'), findsOneWidget);
          expect(
              find.descendant(
                  of: find.byKey(const ValueKey('profile-appearance-row')),
                  matching: find.text({
                    'light': '浅色',
                    'dark': '深色',
                    'colorful': '彩色'
                  }[appearance]!)),
              findsOneWidget);
          expect(tester.takeException(), isNull);
          await captureThemeEvidence(tester, visualKey,
              'profile-layout-$appearance-${width.toInt()}-$scale');
        });
      }
    }
  }

  testWidgets(
      'failed persistence rolls back preview and invalidates unsaved cache',
      (tester) async {
    final settings = _AppearanceSettings()..pending = Completer<void>();
    await pumpProfile(tester, appearanceSettings: settings, followGlobal: true);
    await tester
        .ensureVisible(find.byKey(const ValueKey('profile-appearance-row')));
    await tester.tap(find.byKey(const ValueKey('profile-appearance-row')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('appearance-option-colorful')));
    await tester.pump();
    expect(globalThemeNotifier.value, 'colorful');
    expect(settings.saved, 'light');
    expect(
        tester
            .widget<ListTile>(
                find.byKey(const ValueKey('appearance-option-dark')))
            .enabled,
        isFalse);
    await tester.tap(find.byKey(const ValueKey('appearance-option-dark')));
    expect(settings.calls, 1);
    settings.pending!.completeError(StateError('synthetic failure'));
    await tester.pumpAndSettle();
    expect(globalThemeNotifier.value, 'light');
    expect(await settings.getAppTheme(), 'light');
    expect(settings.invalidations, 1);
    expect(find.text('外观保存失败，已恢复原设置，请重试'), findsOneWidget);
    expect(
        tester
            .widget<ListTile>(
                find.byKey(const ValueKey('appearance-option-light')))
            .selected,
        isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late save failure still rolls back after profile disposal',
      (tester) async {
    final settings = _AppearanceSettings()..pending = Completer<void>();
    await pumpProfile(tester, appearanceSettings: settings, followGlobal: true);
    await tester
        .ensureVisible(find.byKey(const ValueKey('profile-appearance-row')));
    await tester.tap(find.byKey(const ValueKey('profile-appearance-row')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('appearance-option-dark')));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    settings.pending!.completeError(StateError('synthetic failure'));
    await tester.pump();
    expect(globalThemeNotifier.value, 'light');
    expect(settings.invalidations, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'invalid old appearance displays light and chooser supports large text',
      (tester) async {
    globalThemeNotifier.value = 'morandi';
    await pumpProfile(tester,
        size: const Size(320, 1200),
        textScaler: const TextScaler.linear(1.8),
        appearanceSettings: _AppearanceSettings(),
        followGlobal: true);
    await tester
        .ensureVisible(find.byKey(const ValueKey('profile-appearance-row')));
    await tester.tap(find.byKey(const ValueKey('profile-appearance-row')));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<ListTile>(
                find.byKey(const ValueKey('appearance-option-light')))
            .selected,
        isTrue);
    expect(find.text('浅色'), findsWidgets);
    expect(find.text('深色'), findsOneWidget);
    expect(find.text('彩色'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

final class _AppearanceSettings extends SettingsRepository {
  String saved = 'light';
  String? cached;
  int calls = 0;
  int invalidations = 0;
  Completer<void>? pending;

  @override
  Future<void> setAppTheme(String theme) async {
    calls++;
    cached = theme;
    if (pending != null) await pending!.future;
    saved = theme;
  }

  @override
  Future<String> getAppTheme({String defaultTheme = 'light'}) async =>
      cached ?? saved;

  @override
  void clearCache() {
    cached = null;
    invalidations++;
  }
}

void _verifySemanticPalette(ThemeData theme) {
  final tokens = theme.extension<ShirohaThemeTokens>()!;
  expect(theme.colorScheme.primary, tokens.primaryAction);
  expect(theme.colorScheme.secondary, tokens.secondaryAction);
  expect(theme.colorScheme.error, tokens.error);
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

final class _ProfileAiConfigService implements AiConfigPresentationService {
  _ProfileAiConfigService({
    Set<AiCapabilitySlot> failedSlots = const <AiCapabilitySlot>{},
  }) : failedSlots = Set<AiCapabilitySlot>.of(failedSlots);

  final Set<AiCapabilitySlot> failedSlots;

  @override
  Future<AiCapabilityBindingSummary?> bindingSummary(
    AiCapabilitySlot slot,
  ) async {
    if (failedSlots.contains(slot)) throw StateError('PRIVATE_AI_FAILURE');
    final index = AiCapabilitySlot.values.indexOf(slot);
    final names = <String>['DeepSeek', '智谱视觉', '智谱 OCR'];
    final provider = AiProviderRecord(
      providerId: 'provider-$index',
      kind: AiProviderKind.deepseek,
      displayName: 'Provider $index',
      baseUrl: 'https://example.invalid',
      state: AiProviderState.ready,
      revision: 0,
      createdAt: 1,
      updatedAt: 1,
    );
    final model = AiModelRecord(
      origin: AiModelOrigin.providerCatalog,
      modelRef: 'model-$index',
      providerId: provider.providerId,
      canonicalModelId: 'canonical-$index',
      displayName: names[index],
      availability: AiModelAvailability.available,
      firstSeenAt: 1,
      lastSeenAt: 1,
    );
    return AiCapabilityBindingSummary(
      binding: AiCapabilityBinding(
        slot: slot,
        modelRef: model.modelRef,
        temperature: 0.7,
        reasoningEffort: '',
        validationMode: AiBindingValidationMode.verified,
        revision: 0,
        updatedAt: 1,
      ),
      model: model,
      provider: provider,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
