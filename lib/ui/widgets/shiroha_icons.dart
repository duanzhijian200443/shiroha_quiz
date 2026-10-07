import 'package:flutter/material.dart';

enum ShirohaGlyph { parseTasks, trainingConfiguration, assistant }

/// Brand glyphs on a 24×24 canvas with a 1.5-pixel rounded stroke.
/// The task-supplied SVG paths are drawn directly without a new dependency.
class ShirohaIcon extends StatelessWidget {
  const ShirohaIcon(this.glyph, {super.key, this.color});

  final ShirohaGlyph glyph;
  final Color? color;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: SizedBox.square(
          dimension: 24,
          child: CustomPaint(
            painter: ShirohaIconPainter(
              glyph,
              color ??
                  IconTheme.of(context).color ??
                  Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
      );
}

class ShirohaIconPainter extends CustomPainter {
  const ShirohaIconPainter(this.glyph, this.color);

  final ShirohaGlyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    final pen = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    switch (glyph) {
      case ShirohaGlyph.trainingConfiguration:
        final lines = Path()
          ..moveTo(4, 6)
          ..lineTo(7, 6)
          ..moveTo(11, 6)
          ..lineTo(20, 6)
          ..moveTo(4, 12)
          ..lineTo(13, 12)
          ..moveTo(17, 12)
          ..lineTo(20, 12)
          ..moveTo(4, 18)
          ..lineTo(6, 18)
          ..moveTo(10, 18)
          ..lineTo(20, 18);
        canvas.drawPath(lines, pen);
        for (final center in [
          const Offset(9, 6),
          const Offset(15, 12),
          const Offset(8, 18)
        ]) {
          canvas.drawCircle(center, 2, pen);
        }
      case ShirohaGlyph.parseTasks:
        final page = Path()
          ..moveTo(11.5, 21)
          ..lineTo(7, 21)
          ..arcToPoint(const Offset(5, 19), radius: const Radius.circular(2))
          ..lineTo(5, 5)
          ..arcToPoint(const Offset(7, 3), radius: const Radius.circular(2))
          ..lineTo(13.5, 3)
          ..lineTo(19, 8.5)
          ..lineTo(19, 11)
          ..moveTo(13.5, 3)
          ..lineTo(13.5, 6.5)
          ..arcToPoint(const Offset(15.5, 8.5),
              radius: const Radius.circular(2), clockwise: false)
          ..lineTo(19, 8.5)
          ..moveTo(8.5, 9.5)
          ..lineTo(11, 9.5)
          ..moveTo(8.5, 13)
          ..lineTo(10, 13)
          ..moveTo(18, 19)
          ..lineTo(20.5, 21.5);
        canvas.drawPath(page, pen);
        canvas.drawCircle(const Offset(15.5, 16.5), 3.5, pen);
      case ShirohaGlyph.assistant:
        final star = Path()
          ..moveTo(12, 2)
          ..cubicTo(13.3, 8.6, 15.4, 10.7, 22, 12)
          ..cubicTo(15.4, 13.3, 13.3, 15.4, 12, 22)
          ..cubicTo(10.7, 15.4, 8.6, 13.3, 2, 12)
          ..cubicTo(8.6, 10.7, 10.7, 8.6, 12, 2)
          ..close();
        canvas.drawPath(star, pen);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(ShirohaIconPainter oldDelegate) =>
      oldDelegate.glyph != glyph || oldDelegate.color != color;
}
