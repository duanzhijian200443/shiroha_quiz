import '../../domain/appearance/shiroha_appearance.dart';

abstract interface class AppearanceSettingsPort {
  Future<ShirohaAppearance> getAppearance({bool paperDefaultEnabled = false});
  Future<void> setAppearance(ShirohaAppearance appearance);
}

/// One settings seam for startup and Profile; no Flutter or storage DTOs.
final class AppearanceSettingsService {
  const AppearanceSettingsService(this._store,
      {this.paperDefaultEnabled = false});

  final AppearanceSettingsPort _store;

  /// Remains false until formal visual acceptance and rollout authorization.
  final bool paperDefaultEnabled;

  Future<ShirohaAppearance> load() =>
      _store.getAppearance(paperDefaultEnabled: paperDefaultEnabled);

  Future<void> save(ShirohaAppearance appearance) =>
      _store.setAppearance(appearance);
}
