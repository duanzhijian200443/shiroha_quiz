import 'dart:async';
import 'dart:io';

import '../../services/backup/sha256.dart';

enum WindowsCodexClientUse { product, isolatedValidation }

enum WindowsCodexConnectionMode { direct, hosted, appOwnedDevelopment }

enum WindowsCodexClientSupport { unsupported, isolatedValidationOnly }

/// Trusted local executable inspection, never MCP clientInfo or a version claim.
abstract interface class WindowsCodexExecutable {
  Future<String> sha256();
}

final class WindowsCodexExecutableFile implements WindowsCodexExecutable {
  WindowsCodexExecutableFile(this.path);
  final String path;

  @override
  Future<String> sha256() async {
    try {
      return await _readDigest();
    } catch (_) {
      // Filesystem errors may contain the locally selected executable path.
      throw StateError('Codex executable unavailable');
    }
  }

  Future<String> _readDigest() async {
    if (!Platform.isWindows || !File(path).isAbsolute) {
      throw StateError('Codex executable unavailable');
    }
    final digest = StreamingSha256();
    var size = 0;
    await for (final chunk in File(path).openRead()) {
      size += chunk.length;
      if (size > 512 * 1024 * 1024) {
        throw StateError('Codex executable unavailable');
      }
      digest.update(chunk);
    }
    if (size == 0) throw StateError('Codex executable unavailable');
    return digest.digestHex();
  }
}

/// Compatibility only: no authentication, Session, process or credential owner.
/// No official build currently has accepted original-Bridge settlement evidence.
/// The pinned patch is eligible ONLY in an explicitly isolated validation root.
final class WindowsCodexClientSelection {
  WindowsCodexClientSelection._(
      this._executable, this.digest, this.use, this.mode);

  static const isolatedPatchDigest =
      'fb3e30a2e51cef13697d7e42826fc9a6814aff2ce5c5a53d06d019eb79fdfd24';

  static Future<WindowsCodexClientSelection> inspect({
    required WindowsCodexExecutable executable,
    required WindowsCodexClientUse use,
    required WindowsCodexConnectionMode mode,
  }) async =>
      WindowsCodexClientSelection._(
          executable, await executable.sha256(), use, mode);

  final WindowsCodexExecutable _executable;
  final String digest;
  final WindowsCodexClientUse use;
  final WindowsCodexConnectionMode mode;
  bool _discovering = false, _discovered = false, _claimed = false;
  bool _failed = false;

  WindowsCodexClientSupport get support => digest == isolatedPatchDigest
      ? WindowsCodexClientSupport.isolatedValidationOnly
      : WindowsCodexClientSupport.unsupported;

  String get reason =>
      support == WindowsCodexClientSupport.isolatedValidationOnly
          ? 'isolated_patch_not_product_supported'
          : 'original_bridge_lifecycle_not_accepted';

  void _requireEligible() {
    if (_failed ||
        mode == WindowsCodexConnectionMode.appOwnedDevelopment ||
        use != WindowsCodexClientUse.isolatedValidation ||
        support != WindowsCodexClientSupport.isolatedValidationOnly) {
      throw StateError('Codex client unsupported');
    }
  }

  /// A temporary Manager must settle before business. No live-business discovery
  /// is dispatched. The caller supplies its ORIGINAL process/stream settlement,
  /// not a PID disappearance check. Failure is retained; no automatic retry.
  Future<T> discoverBeforeBusiness<T>({
    required Future<T> Function() discover,
    required Future<void> Function() settleOriginal,
  }) async {
    _requireEligible();
    if (_discovering || _discovered || _claimed) {
      throw StateError('Codex discovery unavailable');
    }
    _discovering = true;
    try {
      try {
        return await discover();
      } finally {
        await settleOriginal();
      }
    } catch (_) {
      _failed = true;
      rethrow;
    } finally {
      _discovering = false;
      _discovered = true;
    }
  }

  /// One custody path per selection. Reconnect requires a fresh inspection and
  /// the existing Owner's settlement; this object never releases that Owner.
  Future<void> claim(WindowsCodexConnectionMode expectedMode) async {
    _requireEligible();
    if (_discovering || _claimed || mode != expectedMode) {
      throw StateError('Codex connection unavailable');
    }
    _claimed = true;
    try {
      if (await _executable.sha256() != digest) {
        throw StateError('Codex executable changed');
      }
    } catch (_) {
      _failed = true;
      rethrow;
    }
  }
}
