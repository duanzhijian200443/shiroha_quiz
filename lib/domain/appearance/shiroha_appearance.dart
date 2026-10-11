enum ShirohaThemeStyle { paper, grayscale, colorful }

enum ShirohaDisplayMode { light, dark, system }

/// User preference; system brightness is resolved by the presentation adapter.
final class ShirohaAppearance {
  const ShirohaAppearance({required this.style, required this.mode});

  final ShirohaThemeStyle style;
  final ShirohaDisplayMode mode;

  // Compatibility identities for the original three presets.
  static const light = ShirohaAppearance(
      style: ShirohaThemeStyle.grayscale, mode: ShirohaDisplayMode.light);
  static const dark = ShirohaAppearance(
      style: ShirohaThemeStyle.grayscale, mode: ShirohaDisplayMode.dark);
  static const colorful = ShirohaAppearance(
      style: ShirohaThemeStyle.colorful, mode: ShirohaDisplayMode.light);
  static const paperLight = ShirohaAppearance(
      style: ShirohaThemeStyle.paper, mode: ShirohaDisplayMode.light);

  static ShirohaAppearance fromLegacy(String? value) => switch (value) {
        'dark' => dark,
        'colorful' => colorful,
        _ => light,
      };

  ShirohaAppearance copyWith(
          {ShirohaThemeStyle? style, ShirohaDisplayMode? mode}) =>
      ShirohaAppearance(style: style ?? this.style, mode: mode ?? this.mode);

  /// Legacy preset names remain available to existing diagnostic consumers.
  String get name => this == light
      ? 'light'
      : this == dark
          ? 'dark'
          : this == colorful
              ? 'colorful'
              : '${style.name}_${mode.name}';

  Map<String, Object> toJson() =>
      {'version': 1, 'style': style.name, 'mode': mode.name};

  static ShirohaAppearance? fromJson(Object? value) {
    if (value is! Map<String, dynamic> || value['version'] != 1) return null;
    final style = ShirohaThemeStyle.values
        .where((item) => item.name == value['style'])
        .firstOrNull;
    final mode = ShirohaDisplayMode.values
        .where((item) => item.name == value['mode'])
        .firstOrNull;
    if (style == null || mode == null) return null;
    return ShirohaAppearance(style: style, mode: mode);
  }

  @override
  bool operator ==(Object other) =>
      other is ShirohaAppearance && style == other.style && mode == other.mode;

  @override
  int get hashCode => Object.hash(style, mode);
}
