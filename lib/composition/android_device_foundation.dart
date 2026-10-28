import '../application/external/android_foreground_access.dart';
import '../data/external/android_association_store.dart';
import '../data/external/android_native_association_backend.dart';

/// Source-only construction. No startup caller, listener, keys, policy or P0.
final class AndroidDeviceFoundation {
  AndroidDeviceFoundation(
      {required AndroidNativeCalls native,
      required Duration Function() elapsed,
      required int Function() nowUtcMs})
      : backend = AndroidNativeAssociationBackend(native),
        foreground = AndroidForegroundAccess(elapsed: elapsed) {
    associations = AndroidAssociationStore(backend, nowUtcMs: nowUtcMs);
  }
  static const runtimeAvailable = false;
  final AndroidNativeAssociationBackend backend;
  final AndroidForegroundAccess foreground;
  late final AndroidAssociationStore associations;

  Future<void> close() async {
    backend.invalidate();
    await foreground.dispose();
    await associations.close();
  }
}
