import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../../application/training/training_contracts.dart';
import '../../domain/training/category_key.dart';
import '../../domain/training/training_content_member.dart';
import '../theme/design_tokens.dart';

String trainingCategoryLabel(CategoryKey key) => switch (key) {
      FolderCategoryKey(:final exactFolderName) => exactFolderName,
      UncategorizedCategoryKey() => '未分类题库',
    };

String trainingVisualLabel(CategoryVisualKey key) => switch (key) {
      CategoryVisualKey.math => '数学',
      CategoryVisualKey.english => '英语',
      CategoryVisualKey.computerScience => '计算机',
      CategoryVisualKey.genericLearning => '通用学习',
    };

IconData trainingVisualIcon(CategoryVisualKey? key) => switch (key) {
      CategoryVisualKey.math => Icons.functions_rounded,
      CategoryVisualKey.english => Icons.translate_rounded,
      CategoryVisualKey.computerScience => Icons.code_rounded,
      CategoryVisualKey.genericLearning || null => Icons.auto_stories_outlined,
    };

class CategoryVisualBadge extends StatelessWidget {
  const CategoryVisualBadge(
      {super.key, required this.visualKey, required this.label});
  final CategoryVisualKey? visualKey;
  final String label;

  @override
  Widget build(BuildContext context) => Semantics(
        label:
            '$label分类视觉：${trainingVisualLabel(visualKey ?? CategoryVisualKey.genericLearning)}',
        image: true,
        child: ExcludeSemantics(
          child: Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(
                  DesignTokens.prominentIconContainerRadius),
            ),
            child: Icon(trainingVisualIcon(visualKey),
                size: 30,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
      );
}

class TrainingBankBadge extends StatelessWidget {
  const TrainingBankBadge({super.key});
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
          child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(13)),
        child: Icon(Icons.description_outlined,
            size: 28, color: Theme.of(context).colorScheme.onSurfaceVariant),
      ));
}

class TrainingCard extends StatelessWidget {
  const TrainingCard(
      {super.key,
      required this.child,
      this.padding = const EdgeInsets.all(16)});
  final Widget child;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        elevation: 0,
        color: Theme.of(context).colorScheme.surface,
        shape: RoundedRectangleBorder(
            side: BorderSide(
                color: Theme.of(context)
                    .colorScheme
                    .outlineVariant
                    .withValues(alpha: .5)),
            borderRadius: BorderRadius.circular(DesignTokens.cardRadius)),
        child: Padding(padding: padding, child: child),
      );
}

class TrainingPageBody extends StatelessWidget {
  const TrainingPageBody({super.key, required this.children, this.controller});
  final List<Widget> children;
  final ScrollController? controller;
  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints:
              const BoxConstraints(maxWidth: DesignTokens.contentMaxWidth),
          child: ListView(
              controller: controller,
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: children),
        ),
      );
}

class TrainingSectionHeading extends StatelessWidget {
  const TrainingSectionHeading(
      {super.key, required this.title, this.help, this.action});
  final String title;
  final String? help;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 12),
        child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 8,
            children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                Text(title,
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700)),
                if (help != null)
                  Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Tooltip(
                          message: help!,
                          triggerMode: TooltipTriggerMode.tap,
                          child: Icon(Icons.help_outline,
                              size: 20,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant))),
              ]),
              if (action != null) action!,
            ]),
      );
}

class TrainingRatioOverview extends StatelessWidget {
  const TrainingRatioOverview(
      {super.key, required this.members, required this.limit});
  final List<TrainingContentMember> members;
  final int limit;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label:
          '出题比例总览，$limit题，${members.map((m) => '${m.bankName} ${m.weightPercent}%').join('，')}',
      image: true,
      child: ExcludeSemantics(
          child: SizedBox(
        width: 128,
        height: 128,
        child: CustomPaint(
          painter: _RatioPainter(members.map((m) => m.weightPercent).toList(),
              colors.onSurfaceVariant, colors.surfaceContainerHighest),
          child: Center(
              child: Text('$limit\n题',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge)),
        ),
      )),
    );
  }
}

class _RatioPainter extends CustomPainter {
  _RatioPainter(this.weights, this.foreground, this.background);
  final List<int> weights;
  final Color foreground;
  final Color background;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 16;
    final bounds = rect.deflate(10);
    canvas.drawOval(bounds, paint..color = background);
    var start = -math.pi / 2;
    for (var i = 0; i < weights.length; i++) {
      final sweep = 2 * math.pi * weights[i] / 100;
      paint.color = Color.lerp(foreground, background, (i % 5) * .17)!;
      if (sweep > 0) canvas.drawArc(bounds, start, sweep, false, paint);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_RatioPainter oldDelegate) => true;
}

String trainingInvalidationLabel(TrainingContentMember member) =>
    switch (member.invalidationReason) {
      TrainingBindingInvalidationReason.bankMissing => '原题库已不存在',
      TrainingBindingInvalidationReason.categoryChanged => '题库所属分类已变化',
      TrainingBindingInvalidationReason.bankIneligible => '题库不再可用于普通训练',
      null => '绑定已失效',
    };
