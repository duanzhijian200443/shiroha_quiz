import 'dart:io';
import 'package:path/path.dart' as p;

/// Fixed build-relative adapter and the existing protected pairing slot. Only
/// existence is inspected here; the original adapter owns DPAPI/key access.
final class WindowsAndroidAdapterLayout {
  WindowsAndroidAdapterLayout._(this.executableDirectory, this.recordDirectory);
  static const reference = 'paired-android';
  static const executableName = 'AndroidDeviceAdapter.exe';
  static const files = {
    executableName,
    'AndroidDeviceAdapter.dll',
    'AndroidDeviceAdapter.deps.json',
    'AndroidDeviceAdapter.runtimeconfig.json',
  };
  final String executableDirectory;
  final String recordDirectory;
  static WindowsAndroidAdapterLayout? resolve(String appExecutable) {
    if (!p.isAbsolute(appExecutable)) return null;
    final directory = p.dirname(appExecutable);
    var parent = Directory(directory);
    for (var i = 0; i < 10; i++) {
      if (File(p.join(parent.path, 'pubspec.yaml')).existsSync()) {
        return WindowsAndroidAdapterLayout._(
            directory, p.join(parent.path, 'build', 'android_device_read'));
      }
      final next = parent.parent;
      if (next.path == parent.path) break;
      parent = next;
    }
    return null;
  }

  bool get paired => File(p.join(recordDirectory, 'device.dpapi')).existsSync();
  bool get packagePresent => files
      .every((name) => File(p.join(executableDirectory, name)).existsSync());
}
