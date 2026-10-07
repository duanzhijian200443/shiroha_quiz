import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../theme/design_tokens.dart';
import '../theme/shiroha_theme_tokens.dart';

/// Decorative reference landscape with live text; no simulated measurements.
class TodayWelcomeBanner extends StatelessWidget {
  const TodayWelcomeBanner({super.key, this.now});
  final DateTime? now;
  @override
  Widget build(BuildContext context) {
    final active = AppTheme.withPresetFallback(Theme.of(context))
        .extension<ShirohaThemeTokens>()!;
    final colorful = active.appearance == ShirohaAppearance.colorful;
    // Neutral appearances keep the original bright, grayscale banner asset.
    final tokens = colorful
        ? active
        : AppTheme.lightTheme.extension<ShirohaThemeTokens>()!;
    final landscape = Image.asset('assets/images/today/welcome-landscape.png',
        fit: BoxFit.cover,
        alignment: Alignment.centerRight,
        excludeFromSemantics: true);
    final hour = (now ?? DateTime.now()).hour;
    final greeting = hour < 6
        ? '夜深了'
        : hour < 12
            ? '早上好'
            : hour < 18
                ? '下午好'
                : '晚上好';
    return ClipRRect(
      key: const ValueKey('home-welcome-banner'),
      borderRadius: BorderRadius.circular(DesignTokens.todayCardRadius),
      child: Stack(children: [
        Positioned.fill(
            child: colorful
                ? ColorFiltered(
                    colorFilter: tokens.illustrationFilter, child: landscape)
                : landscape),
        Positioned.fill(
            child: DecoratedBox(
                decoration: BoxDecoration(
                    gradient: LinearGradient(colors: [
          tokens.surface.withValues(alpha: colorful ? .88 : .28),
          tokens.surface.withValues(alpha: colorful ? .04 : 0),
        ], stops: const [
          0,
          .65
        ])))),
        LayoutBuilder(
            builder: (context, constraints) => ConstrainedBox(
                constraints:
                    BoxConstraints(minHeight: constraints.maxWidth * .42),
                child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(width: double.infinity),
                          Text(greeting,
                              style: TextStyle(
                                  fontSize: 24,
                                  height: 1.3,
                                  fontWeight: FontWeight.w700,
                                  color: tokens.textPrimary)),
                          const SizedBox(height: 4),
                          Text('今天也继续加油吧！',
                              style: TextStyle(
                                  fontSize: 14,
                                  height: 1.4,
                                  color: tokens.welcomeCaption)),
                          const SizedBox(height: 10),
                          DecoratedBox(
                              decoration: BoxDecoration(
                                  color: tokens.surface
                                      .withValues(alpha: colorful ? .96 : .8),
                                  borderRadius: BorderRadius.circular(20)),
                              child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 4),
                                  child: Text('保持学习，慢慢进步',
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: tokens.welcomePillText)))),
                        ]))))
      ]),
    );
  }
}

/// Quiet non-interactive landscape at the end of the scrolling page.
class TodayLandscapeDecoration extends StatelessWidget {
  const TodayLandscapeDecoration({super.key});
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
      child: IgnorePointer(
          child: CustomPaint(
              painter: _LandscapePainter(
                  Theme.of(context).colorScheme.onSurfaceVariant))));
}

class _LandscapePainter extends CustomPainter {
  _LandscapePainter(this.ink);
  final Color ink;
  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < 2; i++) {
      final baseline = size.height * (.4 + i * .2);
      final ridge = Path()
        ..moveTo(0, baseline)
        ..cubicTo(size.width * .18, baseline - 25, size.width * .26,
            baseline + 20, size.width * .42, baseline)
        ..cubicTo(size.width * .65, baseline - 28, size.width * .7,
            baseline + 24, size.width, baseline - 10)
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height)
        ..close();
      canvas.drawPath(ridge, Paint()..color = ink.withValues(alpha: .045));
    }
    for (final x in [size.width * .04, size.width * .94]) {
      canvas.save();
      canvas.translate(x, size.height);
      canvas.rotate(x < size.width / 2 ? .2 : -.2);
      canvas.drawLine(
          Offset.zero,
          const Offset(0, -48),
          Paint()
            ..strokeWidth = 1
            ..color = ink.withValues(alpha: .1));
      for (var i = 0; i < 4; i++) {
        final y = -12.0 - i * 10;
        final leaf = Path()
          ..moveTo(0, y)
          ..quadraticBezierTo(-18, y - 3, -14, y - 15)
          ..quadraticBezierTo(-2, y - 13, 0, y)
          ..moveTo(0, y - 5)
          ..quadraticBezierTo(17, y - 8, 13, y - 19)
          ..quadraticBezierTo(2, y - 17, 0, y - 5);
        canvas.drawPath(leaf, Paint()..color = ink.withValues(alpha: .085));
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_LandscapePainter oldDelegate) => oldDelegate.ink != ink;
}
