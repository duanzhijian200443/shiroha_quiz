import 'package:flutter/material.dart';
import '../../domain/study_plan/active_study_plan.dart';
import '../theme/design_tokens.dart';
import 'today_controller.dart';
import 'today_plan_card.dart';

/// Existing singleton-plan operations; this is not a multi-plan manager.
class CurrentPlanScreen extends StatelessWidget {
  const CurrentPlanScreen(
      {super.key,
      required this.controller,
      required this.onStart,
      required this.onStop,
      this.onAskAssistant});
  final TodayController controller;
  final VoidCallback onStart;
  final ValueChanged<ActiveStudyPlan> onStop;
  final VoidCallback? onAskAssistant;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('当前计划')),
        body: AnimatedBuilder(
            animation: controller,
            builder: (context, _) => Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                      constraints: const BoxConstraints(
                          maxWidth: DesignTokens.contentMaxWidth),
                      child: SingleChildScrollView(
                          padding: const EdgeInsets.all(
                              DesignTokens.pageHorizontalPadding),
                          child: TodayPlanCard(
                              state: controller.focusedState,
                              detailed: true,
                              onRetry: controller.loadFocusedState,
                              onStart: controller.practiceStartPending
                                  ? null
                                  : onStart,
                              onStop: onStop,
                              onAskAssistant: onAskAssistant))),
                )),
      );
}
