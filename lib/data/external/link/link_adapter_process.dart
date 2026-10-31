import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../../mcp/link_app_client.dart';
import '../bounded_json_object.dart';
import 'link_installation.dart';
import 'link_values.dart';

abstract interface class LinkBackend {
  LinkVerifiedTarget get target;
  LinkOwnerReference get owner;
  Future<void> get disconnected;
  Future<Map<String, Object?>> call(String tool, Map<String, dynamic> arguments,
      {required Stream<void> cancelled});
  Future<void> close();
}

/// The original adapter owns TLS and keys. This owner joins original process
/// and all three streams AND requires the adapter's bound settlement event.
final class LinkAdapterProcess implements LinkBackend {
  LinkAdapterProcess._(this._process, this.runId, this.resourceId, this.slotRef,
      this._proof, this._windows) {
    _stderr = _readEvents();
    _stdout = _readOutput();
    unawaited(_stderr.then((_) {}, onError: (Object _, StackTrace __) {
      _failed = true;
    }));
    unawaited(_stdout.then((_) {}, onError: (Object _, StackTrace __) {
      _failed = true;
    }));
    unawaited(_process.exitCode.then((_) {
      if (!_identity.isCompleted) {
        _identity.completeError(const LinkException('adapter_unavailable'));
      }
    }));
    unawaited(
        _identity.future.then((_) {}, onError: (Object _, StackTrace __) {}));
    _client = _proof
        ? null
        : LinkAppClient(input: _output.stream, output: _process.stdin);
  }
  final Process _process;
  final String runId, resourceId, slotRef;
  final bool _proof;
  final bool _windows;
  final _output = StreamController<List<int>>.broadcast(sync: true);
  final _identity = Completer<LinkVerifiedTarget>();
  LinkOwnerReference? _owner;
  LinkVerifiedTarget? _target;
  LinkAppClient? _client;
  late final Future<void> _stdout, _stderr;
  Future<void>? _closing;
  bool _settledEvent = false, _failed = false, _inputClosed = false;
  int _diagnosticBytes = 0;

  static Future<LinkAdapterProcess> start(LinkInstallation installation,
      {required String runId,
      required String resourceId,
      required bool proof,
      bool windows = false,
      required Future<void> Function(LinkOwnerReference) acquired}) async {
    final executable = windows
        ? installation.windowsClientExecutable
        : installation.adapterExecutable;
    if (executable == null || windows && proof) linkFail('unavailable');
    final process = await Process.start(
        executable,
        windows
            ? ['--link', runId, resourceId]
            : [
                proof ? '--link-proof' : '--link-business',
                runId,
                resourceId,
                '--current-user-cng-import'
              ],
        runInShell: false,
        workingDirectory: File(executable).parent.path);
    final owned = LinkAdapterProcess._(process, runId, resourceId,
        windows ? 'windows' : installation.slotRef, proof, windows);
    try {
      // Ownership was persisted before Process.start by the caller. Capture the
      // exact original process, even if shutdown races this asynchronous create.
      await acquired(LinkOwnerReference(
          runId: runId,
          resourceId: resourceId,
          processId: process.pid,
          processStarted: 'awaiting-adapter',
          slotRef: owned.slotRef));
      if (proof) {
        await owned.close();
      } else {
        owned._target =
            await owned._identity.future.timeout(const Duration(seconds: 8));
        if (owned._owner == null) linkFail();
        await acquired(owned._owner!);
        await owned._client!.connect();
      }
      return owned;
    } catch (_) {
      try {
        await owned.close();
      } catch (_) {/* Original dirty custody persists. */}
      rethrow;
    }
  }

  @override
  LinkVerifiedTarget get target =>
      _target ?? (throw const LinkException('unavailable'));
  @override
  LinkOwnerReference get owner =>
      _owner ?? (throw const LinkException('unavailable'));
  @override
  Future<void> get disconnected => _process.exitCode.then((_) {});

  Future<void> _readOutput() async {
    var proofBytes = 0;
    try {
      await for (final bytes in _process.stdout) {
        if (_proof) {
          proofBytes += bytes.length;
          if (proofBytes > 16384) _failed = true;
        } else if (_output.hasListener) {
          _output.add(bytes);
        } else {
          _failed = true;
        }
      }
    } finally {
      await _output.close();
    }
  }

  Future<void> _readEvents() async {
    var line = <int>[];
    await for (final chunk in _process.stderr) {
      _diagnosticBytes += chunk.length;
      if (_diagnosticBytes > 32768) {
        _failed = true;
        continue;
      }
      for (final byte in chunk) {
        if (byte == 10) {
          _event(utf8.decode(line, allowMalformed: false).trim());
          line = [];
        } else {
          if (line.length >= 4096) {
            _failed = true;
            continue;
          }
          line.add(byte);
        }
      }
    }
    if (line.isNotEmpty) _failed = true;
  }

  void _event(String line) {
    if (!line.startsWith('SHIROHA_LINK_EVENT ')) {
      return; // Never persist raw diagnostics.
    }
    try {
      final value = boundedJsonObject(
          Uint8List.fromList(utf8.encode(line.substring(19))),
          maxBytes: 4096);
      if (value['runId'] != runId || value['resourceId'] != resourceId) {
        linkFail();
      }
      switch (value['type']) {
        case 'owner':
          linkFields(value, {
            'type',
            'runId',
            'resourceId',
            'processId',
            'processStarted',
            'slotRef'
          });
          if (_owner != null ||
              value['processId'] != _process.pid ||
              value['slotRef'] != slotRef) {
            linkFail();
          }
          _owner = LinkOwnerReference.fromJson({...value}..remove('type'));
        case 'authenticated':
          linkFields(value, {
            'type',
            'runId',
            'resourceId',
            'deviceIdentity',
            'installationIdentity',
            'profileReference'
          });
          if (_proof || _owner == null || _identity.isCompleted) linkFail();
          _identity.complete(LinkVerifiedTarget.fromJson({
            'deviceIdentity': value['deviceIdentity'],
            'installationIdentity': value['installationIdentity'],
            'profileReference': value['profileReference']
          }));
        case 'settled':
          linkFields(value, {
            'type',
            'runId',
            'resourceId',
            'mode',
            'targetClose',
            'tlsShutdown',
            'keyRetired'
          });
          if (_settledEvent ||
              _owner == null ||
              value['mode'] != (_proof ? 'enable-proof' : 'business') ||
              value['targetClose'] != true ||
              value['tlsShutdown'] != true ||
              value['keyRetired'] != true) {
            linkFail();
          }
          _settledEvent = true;
        default:
          linkFail();
      }
    } catch (_) {
      _failed = true;
    }
  }

  @override
  Future<Map<String, Object?>> call(String tool, Map<String, dynamic> arguments,
      {required Stream<void> cancelled}) async {
    if (_closing != null || _failed || _client == null) linkFail('unavailable');
    final result = await _client!.call(tool, arguments, cancelled: cancelled);
    final source = result['source'];
    if (source is! Map ||
        source['kind'] != (_windows ? 'windows' : 'android') ||
        source['deviceRef'] != (_windows ? 'local' : target.deviceIdentity)) {
      linkFail('device_mismatch');
    }
    return result;
  }

  @override
  Future<void> close() => _closing ??= () async {
        // SDK close would abort request handlers. The owning Link first joins its
        // original call; EOF now requests the adapter's graceful target CLOSE.
        if (!_inputClosed) {
          _inputClosed = true;
          try {
            await _process.stdin.flush();
            await _process.stdin.close();
          } catch (_) {
            _failed = true;
          }
        }
        final status = await _process.exitCode;
        await Future.wait([_stdout, _stderr]);
        await _client?.close();
        if (status != 0 || !_settledEvent || _failed) {
          linkFail('owner_unsettled');
        }
      }();
}
