import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../application/external/first_party_development_access.dart';
import 'windows_child_environment.dart';
import 'windows_release_candidate.dart';
import 'windows_process_observation.dart';
import 'windows_android_adapter_layout.dart';

/// Bounded stderr observations and original Future outcomes only. Nothing here
/// decides admission, Pin persistence or successful Owner release.
final class WindowsBridgeProcessDiagnostics {
  static const marker = WindowsPairingProcessReport.marker;
  static const androidRecoveryMarker = 'SHIROHA_ANDROID_RECOVERY|';
  static const androidLinkMarker = 'SHIROHA_ANDROID_LINK|';
  ({String stage, String code})? androidLinkFailure;
  static const _androidRecoveryStages = {
    'configuration',
    'protected-configuration',
    'client-key',
    'tls',
    'hello',
    'offer',
    'proof',
    'settlement',
    'settled',
  };
  static const _androidRecoveryFailures = {
    'runtime_not_authorized',
    'invalid_target',
    'pairing_required',
    'credential_store_corrupt',
    'credential_store_unavailable',
    'credential_commit_unknown',
    'credential_rejected',
    'device_mismatch',
    'stale_revision',
    'protocol_violation',
    'settlement_unknown',
    'peer_lost',
    'resource_limit',
    'socket',
    'tls',
    'eof',
    'deadline',
    'io',
    'invalid_configuration',
  };
  void Function(String stage, String? failure)? onAndroidRecovery;
  static const maxBytes = 8192, maxLine = 128, maxRecords = 32;
  final _parts = <FirstPartyChildPart, FirstPartyObservedResult>{
    for (final part in FirstPartyChildPart.values)
      part: FirstPartyObservedResult.unobserved,
  };
  final _line = <int>[];
  int _bytes = 0, _records = 0;
  bool _discardLine = false;
  int? _exitCode;
  FirstPartyPairingStage? _stage;
  FirstPartyPairingFailure? _primary, _cleanup;
  FirstPartyBusinessStage? _businessStage;
  FirstPartyBusinessFailure? _businessPrimary, _businessCleanup;
  FirstPartyChildObservation get observation => FirstPartyChildObservation(
      parts: _parts,
      exitCode: _exitCode,
      reportedStage: _stage,
      primaryFailure: _primary,
      cleanupFailure: _cleanup,
      businessStage: _businessStage,
      businessPrimary: _businessPrimary,
      businessCleanup: _businessCleanup);

  Future<T> track<T>(FirstPartyChildPart part, Future<T> work) async {
    _parts[part] = FirstPartyObservedResult.pending;
    try {
      final result = await work;
      if (part == FirstPartyChildPart.exit && result is int) _exitCode = result;
      _parts[part] = FirstPartyObservedResult.returned;
      return result;
    } catch (_) {
      _parts[part] = FirstPartyObservedResult.failed;
      rethrow;
    }
  }

  /// A sole stderr consumer calls this. Unknown/binary/oversized output is
  /// discarded without retaining or printing it; parsing never changes drain.
  void observeStderr(List<int> chunk) {
    for (final byte in chunk) {
      if (_bytes >= maxBytes || _records >= maxRecords) {
        _line.clear();
        return;
      }
      _bytes++;
      if (byte == 10) {
        if (!_discardLine) {
          final line = String.fromCharCodes(_line);
          _accept(
              line.endsWith('\r') ? line.substring(0, line.length - 1) : line);
        }
        _line.clear();
        _discardLine = false;
      } else if ((byte < 32 && byte != 13) ||
          byte > 126 ||
          _line.length >= maxLine) {
        _line.clear();
        _discardLine = true;
      } else if (!_discardLine) {
        _line.add(byte);
      }
    }
  }

  void _accept(String line) {
    if (line.startsWith(androidLinkMarker)) {
      final fields = line.substring(androidLinkMarker.length).split('|');
      if (fields.length != 3 ||
          fields[0] != 'P' ||
          !const {'upload', 'download', 'heartbeat', 'connection'}
              .contains(fields[1]) ||
          !_androidRecoveryFailures.contains(fields[2])) {
        return;
      }
      _records++;
      androidLinkFailure ??= (stage: fields[1], code: fields[2]);
      return;
    }
    if (line.startsWith(androidRecoveryMarker)) {
      final fields = line.substring(androidRecoveryMarker.length).split('|');
      if (fields.length < 2 ||
          fields.length > 3 ||
          !_androidRecoveryStages.contains(fields[1])) {
        return;
      }
      final failure = fields.length == 3 ? fields[2] : null;
      if (!((fields[0] == 'S' && failure == null) ||
          (fields[0] == 'P' && _androidRecoveryFailures.contains(failure)))) {
        return;
      }
      _records++;
      try {
        onAndroidRecovery?.call(fields[1], failure);
      } catch (_) {/* Observation cannot interrupt the original drain. */}
      return;
    }
    if (line.startsWith(WindowsBusinessProcessReport.marker)) {
      final fields =
          line.substring(WindowsBusinessProcessReport.marker.length).split('|');
      if (fields.length < 2 || fields.length > 3) return;
      final stages =
          FirstPartyBusinessStage.values.where((v) => v.name == fields[1]);
      if (stages.isEmpty) return;
      if (fields[0] == 'S' && fields.length == 2) {
        _records++;
        _businessStage = stages.first;
      } else if ((fields[0] == 'P' || fields[0] == 'C') && fields.length == 3) {
        final codes = FirstPartyBusinessFailureCode.values
            .where((v) => v.name == fields[2]);
        if (codes.isEmpty) return;
        _records++;
        final failure = FirstPartyBusinessFailure(stages.first, codes.first);
        if (fields[0] == 'P') {
          _businessPrimary ??= failure;
        } else {
          _businessCleanup ??= failure;
        }
      }
      return;
    }
    if (!line.startsWith(marker)) return;
    final fields = line.substring(marker.length).split('|');
    if (fields.length < 2 || fields.length > 3) return;
    final stages =
        FirstPartyPairingStage.values.where((v) => v.name == fields[1]);
    if (stages.isEmpty) return;
    final stage = stages.first;
    if (fields[0] == 'S' && fields.length == 2) {
      _records++;
      _stage = stage;
    } else if ((fields[0] == 'P' || fields[0] == 'C') && fields.length == 3) {
      final codes =
          FirstPartyPairingFailureCode.values.where((v) => v.name == fields[2]);
      if (codes.isEmpty) return;
      _records++;
      final failure = FirstPartyPairingFailure(stage, codes.first);
      if (fields[0] == 'P') {
        _primary ??= failure;
      } else {
        _cleanup ??= failure;
      }
    }
  }
}

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

  /// Transfers the sole client input subscription and exclusive protocol output
  /// use to the SAME adjacent child. No additional MCP server parses these bytes.
  /// The caller retains ownership of the output sink and must not write to it
  /// until settlement; stderr is never forwarded onto the protocol stream.
  WindowsBridgeProcess.stdio({
    required Stream<List<int>> input,
    required IOSink output,
    int profileVersion = 2,
  }) : _io = _AdjacentBridgeProcessIo(
            input: input, output: output, profileVersion: profileVersion);

  /// One fixed first-party UI action in the SAME adjacent Flutter executable.
  /// The action selects a root only; its original parent/preface grant admits it.
  WindowsBridgeProcess.pairingUi({required Stream<List<int>> input})
      : _io = _AdjacentBridgeProcessIo(input: input, pairingUi: true);

  /// Windows App owns the original Android adapter and both stdio streams.
  WindowsBridgeProcess.androidStdio(
      {required Stream<List<int>> input, required IOSink output})
      : _io = _AdjacentBridgeProcessIo(
            input: input, output: output, android: true, profileVersion: 3);

  /// An explicit local recovery uses the original bounded phone enable proof.
  /// No MCP stream, new pairing, or business invocation is supplied.
  WindowsBridgeProcess.androidRecovery(
      {void Function(String stage, String? failure)? onDiagnostic})
      : _io = _AdjacentBridgeProcessIo(android: true, recovery: true) {
    _diagnostics.onAndroidRecovery = onDiagnostic;
  }

  final WindowsBridgeProcessIo _io;
  final _diagnostics = WindowsBridgeProcessDiagnostics();
  FirstPartyChildObservation get observation => _diagnostics.observation;
  ({String stage, String code})? get androidLinkFailure =>
      _diagnostics.androidLinkFailure;
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
      if (_io is _AdjacentBridgeProcessIo && (_io.pairingUi || _io.android)) {
        final expected = _io.android
            ? WindowsAndroidAdapterLayout.files
            : _AdjacentBridgeProcessIo.pairingFiles;
        if (files.keys.toSet().difference(expected).isNotEmpty ||
            files.length != expected.length) {
          throw _unavailable();
        }
        for (final entry in files.entries) {
          if (entry.key.endsWith('.exe') || entry.key.endsWith('.dll')) {
            WindowsExternalReleaseCandidate.inspectX64Pe(entry.value);
          }
        }
      } else {
        WindowsExternalReleaseCandidate.inspect(
            role: ExternalReleaseRole.bridge, files: files);
      }
      if (_stopped) throw _unavailable();
      _createUnknown = true;
      if (_io case final _AdjacentBridgeProcessIo io) {
        io.diagnostics = _diagnostics;
      }
      final child = _child = await _io.create();
      _createUnknown = false;
      _running = true;
      // Observe immediately, including exits during acquisition/attachment.
      unawaited(_diagnostics
          .track(FirstPartyChildPart.exit, child.exitCode)
          .then((code) {
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
    return _closing ??=
        _diagnostics.track(FirstPartyChildPart.settlement, () async {
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
    }());
  }

  static StateError _unavailable() => StateError('Bridge process unavailable');
}

final class _AdjacentBridgeProcessIo implements WindowsBridgeProcessIo {
  _AdjacentBridgeProcessIo(
      {this.input,
      this.output,
      this.pairingUi = false,
      this.android = false,
      this.recovery = false,
      this.profileVersion = 2});
  final Stream<List<int>>? input;
  final IOSink? output;
  final bool pairingUi;
  final bool android;
  final bool recovery;
  final int profileVersion;
  WindowsBridgeProcessDiagnostics? diagnostics;
  static const pairingFiles = {
    'shiroha_quiz.exe',
    'shiroha_relay_native.dll',
    'shiroha_external_native.dll'
  };
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
    for (final name in android
        ? WindowsAndroidAdapterLayout.files
        : pairingUi
            ? pairingFiles
            : WindowsExternalReleaseCandidate.bridgeFiles) {
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
    _executable = context.join(
        root,
        android
            ? WindowsAndroidAdapterLayout.executableName
            : pairingUi
                ? 'shiroha_quiz.exe'
                : WindowsExternalReleaseCandidate.bridgeExecutable);
    return files;
  }

  @override
  Future<WindowsCreatedBridgeProcess> create() async {
    final executable = _executable;
    if (executable == null) throw WindowsBridgeProcess._unavailable();
    _executable = null;
    final layout = android
        ? WindowsAndroidAdapterLayout.resolve(Platform.resolvedExecutable)
        : null;
    if (android && (layout == null || !layout.paired)) {
      throw WindowsBridgeProcess._unavailable();
    }
    _created = await Process.start(
        executable,
        android
            ? [
                recovery ? '--enable-proof' : '--hosted-business',
                layout!.recordDirectory,
                if (!recovery) '--profile=3',
                '--current-user-cng-import'
              ]
            : pairingUi
                ? const ['--shiroha-bridge-pairing-ui']
                : profileVersion == 3
                    ? const ['--profile=3']
                    : const [],
        runInShell: false,
        includeParentEnvironment: false,
        environment: windowsChildEnvironment());
    final result = _DartCreatedBridgeProcess(_created!,
        input: input, output: output, diagnostics: diagnostics!);
    _created = null;
    return result;
  }
}

final class _DartCreatedBridgeProcess implements WindowsCreatedBridgeProcess {
  _DartCreatedBridgeProcess(this._process,
      {Stream<List<int>>? input, IOSink? output, required this.diagnostics}) {
    _input = input == null ? null : StreamIterator(input);
    _pumping = _pumpInput();
    final forwarding =
        diagnostics.track(FirstPartyChildPart.stdout, _forwardOutput(output));
    if (output != null) {
      void outputClosed() {
        if (_outputSettled) return;
        _outputFailed = true;
        _requestClose();
      }

      unawaited(output.done.then((_) => outputClosed(),
          onError: (Object _, StackTrace __) => outputClosed()));
    }
    settlement = Future.wait<int>([
      _process.exitCode,
      forwarding.then((_) => 0),
      diagnostics
          .track(FirstPartyChildPart.stderr, _drainError())
          .then((_) => 0),
      diagnostics
          .track(FirstPartyChildPart.stdin, _inputClosed.future)
          .then((_) => 0),
    ]).then((values) => values.first);
    if (_input != null) {
      unawaited(_pumping.then((_) => _requestClose(),
          onError: (Object _, StackTrace __) => _requestClose()));
    }
    unawaited(_process.exitCode.then((_) => _requestClose(),
        onError: (Object _, StackTrace __) => _requestClose()));
    unawaited(forwarding.then((_) {},
        onError: (Object _, StackTrace __) => _requestClose()));
  }
  final Process _process;
  final WindowsBridgeProcessDiagnostics diagnostics;

  Future<void> _drainError() async {
    await for (final bytes in _process.stderr) {
      try {
        diagnostics.observeStderr(bytes);
      } catch (_) {/* Observation only. */}
    }
  }

  late final StreamIterator<List<int>>? _input;
  late final Future<void> _pumping;
  final _inputClosed = Completer<void>();
  Future<void>? _closing;
  bool _stopped = false, _outputFailed = false, _outputSettled = false;

  Future<void> _forwardOutput(IOSink? output) async {
    if (output == null) {
      await _process.stdout.drain<void>();
      return;
    }
    // The SAME subscription forwards, then discards only after client failure.
    // Draining after failed output lets EOF/real child settlement proceed, but
    // never changes that failure into successful custody release.
    final bytes = StreamIterator(_process.stdout);
    try {
      while (await bytes.moveNext()) {
        if (_outputFailed) continue;
        try {
          output.add(bytes.current);
          await output.flush();
        } catch (_) {
          _outputFailed = true;
          _requestClose();
        }
      }
      if (_outputFailed) throw WindowsBridgeProcess._unavailable();
    } finally {
      _outputSettled = true;
      await bytes.cancel();
    }
  }

  Future<void> _pumpInput() async {
    final input = _input;
    if (input == null) return;
    while (!_stopped && await input.moveNext()) {
      if (_stopped) break;
      _process.stdin.add(input.current);
      // Backpressure: never read the next client chunk before this one settles.
      await _process.stdin.flush();
    }
  }

  void _requestClose() {
    unawaited(closeInput().then((_) {}, onError: (Object _, StackTrace __) {}));
  }

  @override
  Future<int> get exitCode => _process.exitCode;
  @override
  late final Future<int> settlement;
  @override
  Future<void> closeInput() {
    _stopped = true;
    return _closing ??= () async {
      try {
        try {
          await Future.wait([
            if (_input != null) _input.cancel(),
            _pumping,
          ]);
        } finally {
          // EOF still reaches the original child after failed input/cancellation.
          await _process.stdin.close();
        }
        _inputClosed.complete();
      } catch (error, stack) {
        _inputClosed.completeError(error, stack);
        rethrow;
      }
    }();
  }
}
