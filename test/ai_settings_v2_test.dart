import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/ai_config/ai_config_service.dart';
import 'package:shiroha_quiz/domain/ai_config/ai_config_contracts.dart';
import 'package:shiroha_quiz/ui/pages/ai_model_selector_screen.dart';
import 'package:shiroha_quiz/ui/pages/ai_engine_management_screen.dart';
import 'package:shiroha_quiz/ui/pages/ai_provider_settings_screen.dart';
import 'package:shiroha_quiz/ui/pages/ai_settings_screen.dart';
import 'package:shiroha_quiz/ui/theme/app_theme.dart';
import 'package:shiroha_quiz/ui/widgets/shiroha_settings_components.dart';

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
    expect(find.text('基础配置'), findsOneWidget);
    expect(find.text('API 提供商与模型'), findsOneWidget);

    // Provider / Models own the model assets, so 基础配置 comes first.
    final sectionOrder = tester
        .widgetList<ShirohaSectionLabel>(find.byType(ShirohaSectionLabel))
        .map((label) => label.text)
        .toList(growable: false);
    expect(sectionOrder, <String>['基础配置', '能力配置']);

    await tester.tap(
      find.byKey(const ValueKey<String>('ai-service-text-row')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AiModelSelectorScreen), findsOneWidget);
    expect(find.byType(AiEngineManagementScreen), findsNothing);
    expect(find.text('选择模型 · 文本模型'), findsOneWidget);
  });

  testWidgets('provider entry opens the provider and model management page', (
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

    await tester.tap(
      find.byKey(const ValueKey<String>('ai-service-provider-row')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AiProviderSettingsScreen), findsOneWidget);
    expect(find.text('API 提供商与模型'), findsOneWidget);
    expect(find.text('添加提供商'), findsOneWidget);
  });

  testWidgets('model selector confirms explicitly and cancel has zero mutation',
      (tester) async {
    final service = _UiAiConfigService();
    await tester.pumpWidget(
      MaterialApp(
          theme: AppTheme.darkTheme, home: _SelectorHost(service: service)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('open-selector')));
    await tester.pumpAndSettle();

    // No current binding: every provider accordion starts collapsed.
    expect(find.text('Compatible Model'), findsNothing);
    expect(service.applyCalls, 0);

    await tester.tap(
      find.byKey(const ValueKey<String>('provider-header-provider-a')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Compatible Model'), findsOneWidget);

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

  testWidgets('provider accordions group every origin and gate interaction', (
    tester,
  ) async {
    final service = _UiAiConfigService()..binding = _bindingFor('z53');
    tester.view.physicalSize = const Size(800, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        home: AiModelSelectorScreen(
          service: service,
          slot: AiCapabilitySlot.textModel,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The bound model's provider auto-expands; others stay collapsed.
    expect(
      find.byKey(const ValueKey<String>('model-z53')),
      findsOneWidget,
    );
    expect(find.text('当前选择 · 文本模型'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('model-compatible-model')),
      findsNothing,
    );
    expect(find.text('6 个'), findsOneWidget);
    expect(find.text('当前：Glm 5.3'), findsOneWidget);

    expect(find.text('glm-ocr'), findsOneWidget);
    expect(find.text('custom-model'), findsOneWidget);

    // Expanding provider A collapses the auto-expanded provider Z.
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('provider-header-provider-a')),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('provider-header-provider-a')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('model-compatible-model')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey<String>('model-z53')), findsNothing);

    // Explicit unsupported rows stay inside their provider, disabled.
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('provider-header-provider-z')),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('provider-header-provider-z')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('model-compatible-model')),
      findsNothing,
    );
    expect(find.text('Flash Model'), findsOneWidget);
    expect(
      tester
          .widget<RadioListTile<String>>(
            find.byKey(const ValueKey<String>('model-glm-5.3-flash')),
          )
          .enabled,
      isFalse,
    );
    expect(find.text('不支持当前功能'), findsNWidgets(2));

    // displayName == canonicalModelId renders a single line.
    expect(find.text('same-id'), findsOneWidget);

    // Unknown rows stay selectable and drive the confirm button.
    expect(find.text('能力未标注'), findsNWidgets(2));
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('model-unknown-model')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('model-unknown-model')));
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey<String>('model-confirm-button')),
          )
          .onPressed,
      isNotNull,
    );
    expect(service.applyCalls, 0);

    // No top-level "custom model" group; the OpenAI-compatible weak label
    // lives only on its provider header.
    expect(find.text('自定义模型'), findsNothing);
    expect(find.text('自定义/OpenAI兼容'), findsOneWidget);
  });

  testWidgets('search filters to matching providers and restores state', (
    tester,
  ) async {
    final service = _UiAiConfigService()..binding = _bindingFor('z53');
    await tester.pumpWidget(
      MaterialApp(
        home: AiModelSelectorScreen(
          service: service,
          slot: AiCapabilitySlot.textModel,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('model-z53')),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const ValueKey<String>('model-search-field')),
      'flash',
    );
    await tester.pumpAndSettle();
    expect(find.text('Flash Model'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('model-z53')), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('model-compatible-model')),
      findsNothing,
    );
    expect(find.text('我的代理 API'), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey<String>('model-search-field')),
      '',
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('model-z53')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('model-compatible-model')),
      findsNothing,
    );
  });

  testWidgets('capability picker is selection-only without model creation', (
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

    // The picker only selects existing modelRefs; asset creation belongs to
    // provider management.
    expect(
        find.byKey(const ValueKey<String>('add-custom-model')), findsNothing);
    expect(find.text('添加自定义模型'), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Model ID *'), findsNothing);
  });

  testWidgets('empty picker directs users to provider management', (
    tester,
  ) async {
    final service = _UiAiConfigService()..emptySlotModels = true;
    await tester.pumpWidget(
      MaterialApp(
        home: AiModelSelectorScreen(
          service: service,
          slot: AiCapabilitySlot.textModel,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('暂无可选择的模型，请先在「API 提供商与模型」中添加或刷新模型。'), findsOneWidget);
    expect(find.text('添加自定义模型'), findsNothing);
    expect(
        find.byKey(const ValueKey<String>('add-custom-model')), findsNothing);
  });

  testWidgets('Provider editor never pre-fills credential plaintext', (
    tester,
  ) async {
    final service = _UiAiConfigService()..singleProvider = true;
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(home: AiProviderSettingsScreen(service: service)),
    );
    await tester.pumpAndSettle();

    expect(find.text('当前模型 2 个'), findsOneWidget);
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

    // The editor owns this provider's model directory.
    expect(find.byKey(const ValueKey<String>('provider-model-section')),
        findsOneWidget);
    expect(find.text('Compatible Model'), findsOneWidget);
    expect(find.text('官方目录'), findsOneWidget);

    // Adding a model never asks for a Provider again.
    await tester.tap(
      find.byKey(const ValueKey<String>('provider-add-model-button')),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('添加模型'),
      ),
      findsOneWidget,
    );
    expect(find.text('Model ID *'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Provider'),
      ),
      findsNothing,
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('provider-model-id-field')),
      'custom-deepseek-model',
    );
    await tester.tap(find.byKey(const ValueKey<String>('provider-save-model')));
    await tester.pumpAndSettle();
    expect(service.addModelCalls, 1);
    expect(service.lastAddedModelProviderId, 'provider-a');
    expect(service.lastAddedModelId, 'custom-deepseek-model');
    expect(find.text('模型已添加'), findsOneWidget);

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
    final service = _UiAiConfigService()..singleProvider = true;
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
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

  testWidgets('provider cards show their own manageable model count', (
    tester,
  ) async {
    final service = _UiAiConfigService();
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(home: AiProviderSettingsScreen(service: service)),
    );
    await tester.pumpAndSettle();

    expect(find.text('DeepSeek'), findsOneWidget);
    expect(find.text('智谱 OCR'), findsOneWidget);
    expect(find.text('我的代理 API'), findsOneWidget);
    expect(find.text('当前模型 1 个'), findsNWidgets(2));
    expect(find.text('当前模型 6 个'), findsOneWidget);
    expect(find.text('API 提供商与模型'), findsOneWidget);
  });

  testWidgets('each provider editor shows only its own models', (
    tester,
  ) async {
    final service = _UiAiConfigService();
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(home: AiProviderSettingsScreen(service: service)),
    );
    await tester.pumpAndSettle();

    final deepseekCard = find.ancestor(
      of: find.text('DeepSeek'),
      matching: find.byType(ShirohaSurfaceCard),
    );
    await tester.tap(
      find.descendant(of: deepseekCard.first, matching: find.text('编辑')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Compatible Model'), findsOneWidget);
    expect(find.text('官方目录'), findsOneWidget);
    expect(find.text('Glm 5.3'), findsNothing);
    expect(find.text('glm-ocr'), findsNothing);
    expect(find.text('手动添加'), findsNothing);
  });

  testWidgets('curated and userDefined models show inside their provider', (
    tester,
  ) async {
    final service = _UiAiConfigService();
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(home: AiProviderSettingsScreen(service: service)),
    );
    await tester.pumpAndSettle();

    final zhipuCard = find.ancestor(
      of: find.text('智谱 OCR'),
      matching: find.byType(ShirohaSurfaceCard),
    );
    await tester.tap(
      find.descendant(of: zhipuCard.first, matching: find.text('编辑')),
    );
    await tester.pumpAndSettle();

    // glm-ocr stays a curated model of this zhipu provider.
    expect(find.text('glm-ocr'), findsOneWidget);
    expect(find.text('内置'), findsOneWidget);
    expect(find.text('custom-model'), findsOneWidget);
    expect(find.text('手动添加'), findsOneWidget);
    expect(find.text('Compatible Model'), findsNothing);
    expect(find.byKey(const ValueKey<String>('provider-add-model-button')),
        findsOneWidget);
  });

  testWidgets('known provider creation keeps the first model optional', (
    tester,
  ) async {
    final service = _UiAiConfigService();
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(home: AiProviderSettingsScreen(service: service)),
    );
    await tester.pumpAndSettle();

    // Path A: create only, refresh models later.
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
    expect(service.addModelCalls, 0);

    // Path B: create with an explicit first model id.
    await tester.tap(
      find.byKey(const ValueKey<String>('provider-add-button')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('provider-name-field')),
      'Third DeepSeek',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('provider-key-field')),
      'synthetic-secret',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('provider-base-url-field')),
      'https://third.example.invalid',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('provider-first-model-id-field')),
      'hidden-model',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('provider-save-button')),
    );
    await tester.pumpAndSettle();
    expect(service.createCalls, 2);
    expect(service.addModelCalls, 1);
    expect(service.lastAddedModelProviderId, 'created-provider');
    expect(service.lastAddedModelId, 'hidden-model');
  });

  testWidgets('custom model provider requires the first model id', (
    tester,
  ) async {
    final service = _UiAiConfigService();
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(home: AiProviderSettingsScreen(service: service)),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('provider-add-button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('provider-kind-field')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义模型提供商').last);
    await tester.pumpAndSettle();
    expect(find.text('使用 OpenAI Compatible 协议接入未预置的模型提供商。'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey<String>('provider-name-field')),
      'School Relay',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('provider-key-field')),
      'synthetic-secret',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('provider-base-url-field')),
      'https://relay.example.invalid',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('provider-save-button')),
    );
    await tester.pumpAndSettle();
    expect(find.text('自定义模型提供商必须填写首个 Model ID'), findsOneWidget);
    expect(service.createCalls, 0);

    await tester.enterText(
      find.byKey(const ValueKey<String>('provider-first-model-id-field')),
      'relay-model',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('provider-save-button')),
    );
    await tester.pumpAndSettle();
    expect(service.createCalls, 1);
    expect(service.addModelCalls, 1);
    expect(service.lastAddedModelProviderId, 'created-provider');
    expect(service.lastAddedModelId, 'relay-model');
  });

  testWidgets('first model failure keeps the saved provider and offers retry', (
    tester,
  ) async {
    final service = _UiAiConfigService()..failAddCustomModel = true;
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
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
    await tester.enterText(
      find.byKey(const ValueKey<String>('provider-first-model-id-field')),
      'hidden-model',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('provider-save-button')),
    );
    await tester.pumpAndSettle();

    // Partial success: the provider survives and the screen adopts it as an
    // existing editor instead of pretending the whole save failed.
    expect(service.createCalls, 1);
    expect(find.text('API 提供商已保存，但首个模型添加失败，请进入该提供商后重试。'), findsOneWidget);
    expect(find.text('编辑 API 提供商'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('provider-model-section')),
      findsOneWidget,
    );
    expect(find.text('暂无模型。可刷新模型列表或手动添加。'), findsOneWidget);

    // Retry the first model from the provider's own editor.
    service.failAddCustomModel = false;
    await tester.tap(
      find.byKey(const ValueKey<String>('provider-add-model-button')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('provider-model-id-field')),
      'recovered-model',
    );
    await tester.tap(find.byKey(const ValueKey<String>('provider-save-model')));
    await tester.pumpAndSettle();
    expect(service.addModelCalls, 1);
    expect(service.lastAddedModelProviderId, 'created-provider');
    expect(service.lastAddedModelId, 'recovered-model');
    expect(find.text('模型已添加'), findsOneWidget);
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
      find.byKey(const ValueKey<String>('provider-header-provider-a')),
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
          theme: AppTheme.lightTheme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(1.3),
            ),
            child: child!,
          ),
          home: AiProviderEditorScreen(
            service: service,
            existing: AiProviderOverview(
              provider: _UiAiConfigService.providerA,
              credentialState: AiCredentialState.present,
              modelCount: 1,
              hasModelAuthority: true,
            ),
          ),
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

AiCapabilityBindingSummary _bindingFor(String modelRef) {
  final provider = _UiAiConfigService.providerZ;
  final model = _UiAiConfigService.modelByRef[modelRef]!;
  return AiCapabilityBindingSummary(
    binding: AiCapabilityBinding(
      slot: AiCapabilitySlot.textModel,
      modelRef: modelRef,
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
  int addModelCalls = 0;
  int providerRevision = 2;
  int? lastExpectedRevision;
  String? lastReplacementCredential;
  String? lastAddedModelProviderId;
  String? lastAddedModelId;
  AiCapabilitySlot? lastAppliedSlot;
  double? lastAppliedTemperature;
  AiCapabilityBindingSummary? binding;
  bool singleProvider = false;
  bool failAddCustomModel = false;
  bool emptySlotModels = false;
  final Set<String> createdProviderIds = <String>{};

  static final providerA = AiProviderRecord(
    providerId: 'provider-a',
    kind: AiProviderKind.deepseek,
    displayName: 'DeepSeek',
    baseUrl: 'https://api.example.invalid',
    state: AiProviderState.ready,
    revision: 2,
    createdAt: 1,
    updatedAt: 2,
  );

  static final providerZ = AiProviderRecord(
    providerId: 'provider-z',
    kind: AiProviderKind.zhipu,
    displayName: '智谱 OCR',
    baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
    state: AiProviderState.ready,
    revision: 2,
    createdAt: 1,
    updatedAt: 2,
  );

  static final providerC = AiProviderRecord(
    providerId: 'provider-c',
    kind: AiProviderKind.openAiCompatible,
    displayName: '我的代理 API',
    baseUrl: 'https://proxy.example.invalid',
    state: AiProviderState.ready,
    revision: 2,
    createdAt: 1,
    updatedAt: 2,
  );

  static final compatible = AiModelRecord(
    origin: AiModelOrigin.providerCatalog,
    modelRef: 'compatible-model',
    providerId: providerA.providerId,
    canonicalModelId: 'compatible-canonical',
    displayName: 'Compatible Model',
    availability: AiModelAvailability.available,
    firstSeenAt: 1,
    lastSeenAt: 2,
  );

  static final z53 = AiModelRecord(
    origin: AiModelOrigin.providerCatalog,
    modelRef: 'z53',
    providerId: providerZ.providerId,
    canonicalModelId: 'glm-5.3',
    displayName: 'Glm 5.3',
    availability: AiModelAvailability.available,
    firstSeenAt: 1,
    lastSeenAt: 2,
  );

  static final zflash = AiModelRecord(
    origin: AiModelOrigin.providerCatalog,
    modelRef: 'glm-5.3-flash',
    providerId: providerZ.providerId,
    canonicalModelId: 'glm-5.3-flash',
    displayName: 'Flash Model',
    availability: AiModelAvailability.available,
    firstSeenAt: 1,
    lastSeenAt: 2,
  );

  static final zocr = AiModelRecord(
    origin: AiModelOrigin.curated,
    modelRef: 'glm-ocr',
    providerId: providerZ.providerId,
    canonicalModelId: 'glm-ocr',
    displayName: 'glm-ocr',
    availability: AiModelAvailability.available,
    firstSeenAt: 1,
    lastSeenAt: 2,
  );

  static final zunknown = AiModelRecord(
    origin: AiModelOrigin.providerCatalog,
    modelRef: 'unknown-model',
    providerId: providerZ.providerId,
    canonicalModelId: 'unknown-model',
    displayName: 'Unknown Model',
    availability: AiModelAvailability.available,
    firstSeenAt: 1,
    lastSeenAt: 2,
  );

  static final zcustom = AiModelRecord(
    origin: AiModelOrigin.userDefined,
    modelRef: 'custom-model',
    providerId: providerZ.providerId,
    canonicalModelId: 'custom-model',
    displayName: 'custom-model',
    availability: AiModelAvailability.available,
    firstSeenAt: 1,
    lastSeenAt: 2,
  );

  static final zsame = AiModelRecord(
    origin: AiModelOrigin.providerCatalog,
    modelRef: 'same-id',
    providerId: providerZ.providerId,
    canonicalModelId: 'same-id',
    displayName: 'same-id',
    availability: AiModelAvailability.available,
    firstSeenAt: 1,
    lastSeenAt: 2,
  );

  static final proxy = AiModelRecord(
    origin: AiModelOrigin.userDefined,
    modelRef: 'proxy-model',
    providerId: providerC.providerId,
    canonicalModelId: 'proxy-model',
    displayName: 'Proxy Model',
    availability: AiModelAvailability.available,
    firstSeenAt: 1,
    lastSeenAt: 2,
  );

  static final modelByRef = <String, AiModelRecord>{
    'compatible-model': compatible,
    'z53': z53,
    'glm-5.3-flash': zflash,
    'glm-ocr': zocr,
    'unknown-model': zunknown,
    'custom-model': zcustom,
    'same-id': zsame,
    'proxy-model': proxy,
  };

  AiProviderRecord _providerFor(String providerId) => switch (providerId) {
        'provider-a' => providerA,
        'provider-z' => providerZ,
        _ => providerC,
      };

  AiModelCompatibility _entry(
    AiModelRecord model, {
    required AiModelSelectionState state,
    Map<AiModelCapability, AiCapabilitySupport>? capabilities,
    List<String> reasonCodes = const <String>[],
  }) =>
      AiModelCompatibility(
        model: model,
        provider: _providerFor(model.providerId),
        capabilities: capabilities ??
            const <AiModelCapability, AiCapabilitySupport>{
              AiModelCapability.textInput: AiCapabilitySupport.unknown,
              AiModelCapability.textOutput: AiCapabilitySupport.unknown,
            },
        selectionState: state,
        reasonCodes: reasonCodes,
      );

  @override
  Future<AiCapabilityBindingSummary?> bindingSummary(
    AiCapabilitySlot slot,
  ) async =>
      binding;

  @override
  Future<List<AiModelCompatibility>> listModelsForSlot(
    AiCapabilitySlot slot,
  ) async {
    if (emptySlotModels) return const <AiModelCompatibility>[];
    return <AiModelCompatibility>[
      _entry(
        compatible,
        state: AiModelSelectionState.selectable,
        capabilities: const <AiModelCapability, AiCapabilitySupport>{
          AiModelCapability.textInput: AiCapabilitySupport.supported,
          AiModelCapability.textOutput: AiCapabilitySupport.supported,
        },
      ),
      _entry(
        z53,
        state: AiModelSelectionState.selectable,
        capabilities: const <AiModelCapability, AiCapabilitySupport>{
          AiModelCapability.textInput: AiCapabilitySupport.supported,
          AiModelCapability.textOutput: AiCapabilitySupport.supported,
        },
      ),
      _entry(
        zflash,
        state: AiModelSelectionState.unsupported,
        capabilities: const <AiModelCapability, AiCapabilitySupport>{
          AiModelCapability.textInput: AiCapabilitySupport.unsupported,
          AiModelCapability.imageInput: AiCapabilitySupport.supported,
          AiModelCapability.textOutput: AiCapabilitySupport.supported,
        },
        reasonCodes: const <String>['unsupported:textInput'],
      ),
      _entry(
        zocr,
        state: AiModelSelectionState.unsupported,
        capabilities: const <AiModelCapability, AiCapabilitySupport>{
          AiModelCapability.ocr: AiCapabilitySupport.supported,
          AiModelCapability.textOutput: AiCapabilitySupport.supported,
          AiModelCapability.textInput: AiCapabilitySupport.unsupported,
          AiModelCapability.imageInput: AiCapabilitySupport.unsupported,
        },
        reasonCodes: const <String>['unsupported:textInput'],
      ),
      _entry(zunknown, state: AiModelSelectionState.unannotated),
      _entry(zcustom, state: AiModelSelectionState.unannotated),
      _entry(
        zsame,
        state: AiModelSelectionState.selectable,
        capabilities: const <AiModelCapability, AiCapabilitySupport>{
          AiModelCapability.textInput: AiCapabilitySupport.supported,
          AiModelCapability.textOutput: AiCapabilitySupport.supported,
        },
      ),
      _entry(
        proxy,
        state: AiModelSelectionState.selectable,
        capabilities: const <AiModelCapability, AiCapabilitySupport>{
          AiModelCapability.textInput: AiCapabilitySupport.supported,
          AiModelCapability.textOutput: AiCapabilitySupport.supported,
        },
      ),
    ];
  }

  @override
  Future<List<AiModelRecord>> listModelsForProvider(String providerId) async =>
      <AiModelRecord>[
        for (final model in modelByRef.values)
          if (model.providerId == providerId &&
              model.availability == AiModelAvailability.available)
            model,
      ];

  @override
  Future<List<AiProviderOverview>> listProviders() async {
    final overviews = <AiProviderOverview>[
      if (singleProvider)
        AiProviderOverview(
          provider: AiProviderRecord(
            providerId: providerA.providerId,
            kind: providerA.kind,
            displayName: providerA.displayName,
            baseUrl: providerA.baseUrl,
            state: providerA.state,
            revision: providerRevision,
            createdAt: 1,
            updatedAt: 2,
          ),
          credentialState: AiCredentialState.present,
          modelCount: 2,
          hasModelAuthority: true,
        )
      else
        ...<AiProviderRecord>[providerA, providerZ, providerC].map(
          (provider) => AiProviderOverview(
            provider: provider,
            credentialState: AiCredentialState.present,
            modelCount: provider.providerId == 'provider-z' ? 6 : 1,
            hasModelAuthority: true,
          ),
        ),
    ];
    for (final providerId in createdProviderIds) {
      overviews.add(
        AiProviderOverview(
          provider: AiProviderRecord(
            providerId: providerId,
            kind: AiProviderKind.deepseek,
            displayName: 'Second DeepSeek',
            baseUrl: 'https://second.example.invalid',
            state: AiProviderState.ready,
            revision: 0,
            createdAt: 1,
            updatedAt: 2,
          ),
          credentialState: AiCredentialState.present,
          modelCount: 0,
          hasModelAuthority: false,
        ),
      );
    }
    return overviews;
  }

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
    createdProviderIds.add('created-provider');
    return 'created-provider';
  }

  @override
  Future<String> addCustomModel({
    required String providerId,
    required String canonicalModelId,
    String? displayName,
  }) async {
    if (failAddCustomModel) {
      throw const AiConfigException(AiConfigFailure.invalidInput);
    }
    addModelCalls++;
    lastAddedModelProviderId = providerId;
    lastAddedModelId = canonicalModelId;
    return 'added-model-ref';
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
