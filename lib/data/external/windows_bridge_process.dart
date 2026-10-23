import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'windows_release_candidate.dart';

/// Custody only, never process identity or authority. Unknown exit must fail.
abstract interface class McpVnextWindowsProcessOwner {
  Future<void> stopAndWait();
}

abstract interface class McpVnextWindowsObservedProcessOwner
    implements McpVnextWindowsProcessOwner {
  bool get isCurrent;
  Future<void> get exited;
}

/// Trusted infrastructure seam. No path, arguments, PID or request data enters
/// process creation. A successful create transfers the original process object.
abstract interface class WindowsBridgeProcessIo {
  Future<Map<String, Uint8List>> inspect();
  Future<WindowsCreatedBridgeProcess> create();
}

abstract interface class WindowsCreatedBridgeProcess {
  Future<void> closeInput();
  Future<int> get exitCode;
  Future<int> get settlement;
}

/// Fixed adjacent candidate only. Construction performs no OS operation.
/// EOF is the existing stdio shutdown signal; no kill-by-PID, retry, watchdog,
/// private handshake or elevated execution is supplied. A child that does not
/// exit keeps settlement pending and therefore keeps its caller's Owner held.
final class WindowsBridgeProcess
    implements McpVnextWindowsObservedProcessOwner {
  WindowsBridgeProcess({WindowsBridgeProcessIo? io})
      : _io = io ?? _AdjacentBridgeProcessIo();

  final WindowsBridgeProcessIo _io;
  WindowsCreatedBridgeProcess? _child;
  Future<void>? _starting, _closing;
  final _exited = Completer<void>();
  bool _stopped = false, _running = false, _unknown = false;
  bool _inspectionUnknown = false, _createUnknown = false;
  @override
  bool get isCurrent => _running && !_stopped && !_unknown;

  /// Notification only. Cleanup still joins stopAndWait and original settlement.
  @override
  Future<void> get exited => _exited.future;

  Future<void> start() {
    if (_starting != null || _stopped) throw _unavailable();
    return _starting = _start();
  }

  Future<void> _start() async {
    try {
      // Inspection failure can include an unconfirmed file-handle close.
      _inspectionUnknown = true;
      final files = await _io.inspect();
      _inspectionUnknown = false;
      WindowsExternalReleaseCandidate.inspect(
          role: ExternalReleaseRole.bridge, files: files);
      if (_stopped) throw _unavailable();
      _createUnknown = true;
      final child = _child = await _io.create();
      _createUnknown = false;
      _running = true;
      // Observe immediately, including exits during acquisition/attachment.
      unawaited(child.exitCode.then((code) {
        _running = false;
        if (code != 0) _unknown = true;
        if (!_exited.isCompleted) _exited.complete();
      }, onError: (Object _, StackTrace __) {
        _running = false;
        _unknown = true;
        if (!_exited.isCompleted) _exited.complete();
      }));
      unawaited(
          child.settlement.then((_) {}, onError: (Object _, StackTrace __) {
        _running = false;
        _unknown = true;
        if (!_exited.isCompleted) _exited.complete();
      }));
      if (_stopped) throw _unavailable();
    } catch (_) {
      _stopped = true;
      // A returned child is ours even when stop interrupted the create Future.
      // create must transfer or retain its own partial resources on failure.
      throw _unavailable();
    }
  }

  @override
  Future<void> stopAndWait() {
    _stopped = true;
    return _closing ??= () async {
      try {
        await _starting;
      } catch (_) {/* Still join a child returned during interrupted launch. */}
      if (_inspectionUnknown || _createUnknown) throw _unavailable();
      final child = _child;
      if (child == null) return;
      try {
        await Future.wait([
          Future<void>.sync(child.closeInput),
          child.exitCode.then((code) {
            if (code != 0) throw _unavailable();
          }),
          child.settlement.then((code) {
            if (code != 0) throw _unavailable();
          }),
        ]);
        if (_unknown) throw _unavailable();
        _child = null;
      } catch (_) {
        _unknown = true;
        throw _unavailable();
      }
    }();
  }

  static StateError _unavailable() => StateError('Bridge process unavailable');
}

final class _AdjacentBridgeProcessIo implements WindowsBridgeProcessIo {
  String? _executable;
  RandomAccessFile? _inspection;
  Process? _created;
  @override
  Future<Map<String, Uint8List>> inspect() async {
    if (!Platform.isWindows) throw WindowsBridgeProcess._unavailable();
    final context = p.Context(style: p.Style.windows);
    final resolved = Platform.resolvedExecutable;
    if (!context.isAbsolute(resolved)) {
      throw WindowsBridgeProcess._unavailable();
    }
    final root = context.dirname(resolved);
    final files = <String, Uint8List>{};
    for (final name in WindowsExternalReleaseCandidate.bridgeFiles) {
      // Bounded reads, fixed two names; no scan or caller-selected installation.
      final file = File(context.join(root, name));
      _inspection = await file.open();
      final handle = _inspection!;
      try {
        final size = await handle.length();
        if (size <= 0 || size > 128 * 1024 * 1024) {
          throw WindowsBridgeProcess._unavailable();
        }
        final bytes = await handle.read(size);
        if (bytes.length != size) throw WindowsBridgeProcess._unavailable();
        files[name] = bytes;
      } finally {
        await handle.close();
        _inspection = null;
      }
    }
    _executable =
        context.join(root, WindowsExternalReleaseCandidate.bridgeExecutable);
    return files;
  }

  @override
  Future<WindowsCreatedBridgeProcess> create() async {
    final executable = _executable;
    if (executable == null) throw WindowsBridgeProcess._unavailable();
    _executable = null;
    _created = await Process.start(executable, const [],
        runInShell: false,
        includeParentEnvironment: false,
        environment: const {});
    final result = _DartCreatedBridgeProcess(_created!);
    _created = null;
    return result;
  }
}

final class _DartCreatedBridgeProcess implements WindowsCreatedBridgeProcess {
  _DartCreatedBridgeProcess(this._process) {
    // Discard output without logging; both original streams must settle too.
    settlement = Future.wait<int>([
      _process.exitCode,
      _process.stdout.drain<void>().then((_) => 0),
      _process.stderr.drain<void>().then((_) => 0),
    ]).then((values) => values.first);
  }
  final Process _process;
  @override
  Future<int> get exitCode => _process.exitCode;
  @override
  late final Future<int> settlement;
  @override
  Future<void> closeInput() => _process.stdin.close();
}
