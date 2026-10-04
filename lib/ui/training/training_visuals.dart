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

class TrainingCard extends StatelessWidget {
  const TrainingCard({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        elevation: 0,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(DesignTokens.cardRadius)),
        child: Padding(padding: const EdgeInsets.all(16), child: child),
      );
}

class TrainingPageBody extends StatelessWidget {
  const TrainingPageBody({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints:
              const BoxConstraints(maxWidth: DesignTokens.contentMaxWidth),
          child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: children),
        ),
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
