import 'dart:typed_data';
import 'package:path/path.dart' as p;

enum ExternalReleaseRole { app, bridge }

/// Static package contract, never a loader, launcher or activation decision.
/// Inputs are bounded inspection results from a trusted build inventory. No
/// directory traversal, environment lookup, download or repair is performed.
final class WindowsExternalReleaseCandidate {
  static const nativeAbi = 3;
  static const nativeLibrary = 'shiroha_external_native.dll';
  static const bridgeExecutable = 'shiroha_bridge.exe';
  static const appFiles = {
    'shiroha_quiz.exe',
    'flutter_windows.dll',
    nativeLibrary,
    'data/app.so',
    'data/icudtl.dat',
    'data/flutter_assets/AssetManifest.bin',
  };
  static const bridgeFiles = {bridgeExecutable, nativeLibrary};

  /// The unactivated entry accepts no runtime/environment configuration. A
  /// future explicitly authorized activation must define its own reviewed gate.
  static bool acceptsArguments(List<String> arguments) => arguments.isEmpty;

  static void inspect(
      {required ExternalReleaseRole role,
      required Map<String, Uint8List> files,
      Set<String> declaredPluginLibraries = const {}}) {
    if (files.length > 4096 ||
        (role == ExternalReleaseRole.bridge &&
            declaredPluginLibraries.isNotEmpty)) {
      _reject();
    }
    for (final name in declaredPluginLibraries) {
      if (!RegExp(r'^[a-zA-Z0-9_]+\.dll$').hasMatch(name) ||
          name == nativeLibrary ||
          name == 'flutter_windows.dll') {
        _reject();
      }
    }
    final required = role == ExternalReleaseRole.app ? appFiles : bridgeFiles;
    for (final name in {...required, ...declaredPluginLibraries}) {
      if (files[name]?.isNotEmpty != true) _reject();
    }
    for (final entry in files.entries) {
      if (p.posix.normalize(entry.key) != entry.key) _reject();
      // Exact build-relative names only; no arbitrary fallback path or traversal.
      if (!required.contains(entry.key) &&
          !declaredPluginLibraries.contains(entry.key) &&
          !(role == ExternalReleaseRole.app &&
              RegExp(r'^data/flutter_assets/[a-zA-Z0-9_./-]+$')
                  .hasMatch(entry.key) &&
              !p.posix.split(entry.key).contains('..'))) {
        _reject();
      }
      if (['.dll', '.exe'].contains(p.posix.extension(entry.key))) {
        inspectX64Pe(entry.value);
      }
    }
  }

  /// DOS/PE signature, bounded offset, x64 machine and PE32+ optional header.
  /// This is static structure only: exports/imports/ABI/hashes remain separate
  /// gates and these bytes are never loaded or executed.
  static void inspectX64Pe(Uint8List bytes) {
    if (bytes.length < 64 || bytes[0] != 0x4d || bytes[1] != 0x5a) _reject();
    final data = ByteData.sublistView(bytes);
    final pe = data.getUint32(0x3c, Endian.little);
    if (pe < 64 ||
        pe > bytes.length - 26 ||
        data.getUint32(pe, Endian.little) != 0x00004550 ||
        data.getUint16(pe + 4, Endian.little) != 0x8664 ||
        data.getUint16(pe + 20, Endian.little) < 2 ||
        data.getUint16(pe + 20, Endian.little) > bytes.length - pe - 24 ||
        data.getUint16(pe + 24, Endian.little) != 0x20b) {
      _reject();
    }
  }

  static Never _reject() =>
      throw const FormatException('invalidReleaseCandidate');
}
