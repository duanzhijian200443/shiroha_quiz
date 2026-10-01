import 'package:flutter/material.dart';

/// Reference palette scoped to Today; other destinations keep the app theme.
ThemeData todayVisualTheme(ThemeData base) {
  final dark = base.brightness == Brightness.dark;
  final ink = dark ? const Color(0xFFEAEAF0) : const Color(0xFF303238);
  final muted = dark ? const Color(0xFFB4B5BE) : const Color(0xFF858891);
  final surface = dark ? const Color(0xFF24252B) : Colors.white;
  final canvas = dark ? const Color(0xFF191A20) : const Color(0xFFF7F7FA);
  final tile = dark ? const Color(0xFF33343D) : const Color(0xFFF0F0F5);
  final line = dark ? const Color(0xFF3B3C45) : const Color(0xFFF0F0F3);
  final colors = base.colorScheme.copyWith(
    primary: ink,
    onPrimary: surface,
    primaryContainer: tile,
    onPrimaryContainer: ink,
    surface: surface,
    onSurface: ink,
    onSurfaceVariant: muted,
    surfaceContainerLow: surface,
    surfaceContainerHighest: tile,
    outline: muted,
    outlineVariant: line,
  );
  return base.copyWith(
    colorScheme: colors,
    scaffoldBackgroundColor: canvas,
    textTheme: base.textTheme.apply(bodyColor: ink, displayColor: ink),
    iconTheme: IconThemeData(color: muted),
    cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
  );
}

class TodayIconTile extends StatelessWidget {
  const TodayIconTile(this.icon,
      {super.key, this.size = 34, this.iconSize = 23});
  final IconData icon;
  final double size;
  final double iconSize;
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(size * .25)),
        child: Icon(icon,
            size: iconSize,
            color: Theme.of(context).colorScheme.onSurfaceVariant),
      );
}
