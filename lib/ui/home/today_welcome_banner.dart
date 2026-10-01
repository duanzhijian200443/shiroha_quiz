import 'package:flutter/material.dart';

/// Decorative reference landscape with live text; no simulated measurements.
class TodayWelcomeBanner extends StatelessWidget {
  const TodayWelcomeBanner({super.key});
  @override
  Widget build(BuildContext context) {
    final hour = DateTime.now().hour;
    final greeting = hour < 6
        ? '夜深了'
        : hour < 12
            ? '早上好'
            : hour < 18
                ? '下午好'
                : '晚上好';
    return ClipRRect(
      key: const ValueKey('home-welcome-banner'),
      borderRadius: BorderRadius.circular(14),
      child: Stack(children: [
        Positioned.fill(
            child: Image.asset('assets/images/today/welcome-landscape.png',
                fit: BoxFit.cover, excludeFromSemantics: true)),
        LayoutBuilder(
            builder: (context, constraints) => ConstrainedBox(
                constraints:
                    BoxConstraints(minHeight: constraints.maxWidth / 3.5),
                child: Padding(
                    padding: const EdgeInsets.fromLTRB(28, 12, 24, 12),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(width: double.infinity),
                          Text(greeting,
                              style: const TextStyle(
                                  fontSize: 22,
                                  height: 1.3,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF303238))),
                          const SizedBox(height: 4),
                          const Text('今天也继续加油吧！',
                              style: TextStyle(
                                  fontSize: 13,
                                  height: 1.4,
                                  color: Color(0xFF747780))),
                          const SizedBox(height: 10),
                          DecoratedBox(
                              decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: .8),
                                  borderRadius: BorderRadius.circular(20)),
                              child: const Padding(
                                  padding: EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 4),
                                  child: Text('保持学习，慢慢进步',
                                      style: TextStyle(
                                          fontSize: 10,
                                          color: Color(0xFF555760))))),
                        ]))))
      ]),
    );
  }
}
