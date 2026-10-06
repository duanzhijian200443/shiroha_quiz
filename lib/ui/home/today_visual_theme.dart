import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../theme/shiroha_theme_tokens.dart';

/// Reference palette shared by Today, TaskCenter and bank detail destinations.
ThemeData todayVisualTheme(ThemeData base) {
  final theme = AppTheme.withPresetFallback(base);
  return theme.copyWith(
    cardTheme: CardThemeData(
        color: theme.colorScheme.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
  );
}

class TodayIconTile extends StatelessWidget {
  const TodayIconTile(this.icon,
      {super.key, this.size = 34, this.iconSize = 23, this.circular = false});
  final IconData icon;
  final double size;
  final double iconSize;
  final bool circular;
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(size * (circular ? .5 : .25))),
        child: Icon(icon,
            size: iconSize,
            color: Theme.of(context).extension<ShirohaThemeTokens>()?.icon ??
                Theme.of(context).colorScheme.onSurface),
      );
}

/// Shared thin-stroke vocabulary for the brand and header actions.
class TodayHeaderIcon extends StatelessWidget {
  const TodayHeaderIcon(
      {super.key, this.document = false, required this.color});
  final bool document;
  final Color color;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
      child: SizedBox.square(
          dimension: 25,
          child: CustomPaint(painter: _HeaderIconPainter(color, document))));
}

class _HeaderIconPainter extends CustomPainter {
  _HeaderIconPainter(this.color, this.document);
  final Color color;
  final bool document;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 25, size.height / 25);
    final pen = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.65
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    if (document) {
      final page = Path()
        ..moveTo(10, 21)
        ..lineTo(4, 21)
        ..quadraticBezierTo(2, 21, 2, 19)
        ..lineTo(2, 4)
        ..quadraticBezierTo(2, 2, 4, 2)
        ..lineTo(17, 2)
        ..quadraticBezierTo(19, 2, 19, 4)
        ..lineTo(19, 9);
      canvas.drawPath(page, pen);
      canvas.drawLine(const Offset(6, 7), const Offset(15, 7), pen);
      canvas.drawLine(const Offset(6, 11), const Offset(10, 11), pen);
      canvas.drawLine(const Offset(6, 15), const Offset(8, 15), pen);
      canvas.drawCircle(const Offset(16, 16), 4.5, pen);
      canvas.drawLine(const Offset(19.5, 19.5), const Offset(23, 23), pen);
    } else {
      final book = Path()
        ..moveTo(12.5, 5)
        ..quadraticBezierTo(7, 1.5, 2, 3)
        ..lineTo(2, 21)
        ..quadraticBezierTo(7, 19, 12.5, 23)
        ..quadraticBezierTo(18, 19, 23, 21)
        ..lineTo(23, 3)
        ..quadraticBezierTo(18, 1.5, 12.5, 5)
        ..lineTo(12.5, 23);
      canvas.drawPath(book, pen);
    }
  }

  @override
  bool shouldRepaint(_HeaderIconPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.document != document;
}
