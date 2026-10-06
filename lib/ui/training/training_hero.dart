import 'package:flutter/material.dart';
import '../../application/training/training_contracts.dart';
import '../home/today_category_visual.dart';

class TrainingHero extends StatelessWidget {
  const TrainingHero(
      {super.key,
      required this.title,
      required this.subtitle,
      required this.categoryLabel,
      required this.visualKey,
      this.expanded = false,
      this.previous,
      this.next});
  final String title;
  final String subtitle;
  final String categoryLabel;
  final CategoryVisualKey? visualKey;
  final bool expanded;
  final Widget? previous;
  final Widget? next;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final scale = MediaQuery.textScalerOf(context).scale(1);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: SizedBox(
              height: (expanded ? 224.0 : 140.0) + (scale - 1) * 80,
              child: Stack(fit: StackFit.expand, children: [
                ColoredBox(color: colors.surfaceContainerHighest),
                TodayCategoryVisual(visualKey: visualKey, label: categoryLabel),
                Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .headlineSmall
                                  ?.copyWith(fontWeight: FontWeight.w700)),
                          const SizedBox(height: 8),
                          Text(subtitle,
                              style: TextStyle(color: colors.onSurfaceVariant)),
                          if (expanded) ...[
                            const Spacer(),
                            Text('选择题库，\n按自己的节奏配置训练。',
                                style: TextStyle(
                                    color: colors.onSurfaceVariant,
                                    height: 1.8)),
                          ],
                        ])),
                if (previous != null)
                  Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      child: Center(child: previous!)),
                if (next != null)
                  Positioned(
                      right: 0, top: 0, bottom: 0, child: Center(child: next!)),
                Positioned(
                    top: 0,
                    right: 0,
                    child: ExcludeSemantics(
                        child: CustomPaint(
                            size: const Size(28, 28),
                            painter: _PaperCornerPainter(colors.surface)))),
              ]))),
    );
  }
}

class _PaperCornerPainter extends CustomPainter {
  _PaperCornerPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..quadraticBezierTo(1, size.height, size.width, size.height)
      ..lineTo(size.width, 0)
      ..close();
    canvas.drawShadow(path, Colors.black.withValues(alpha: .2), 4, false);
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_PaperCornerPainter oldDelegate) =>
      oldDelegate.color != color;
}
