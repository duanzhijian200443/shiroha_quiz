import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../../mcp/link_app_client.dart';
import '../bounded_json_object.dart';
import 'link_installation.dart';
import 'link_values.dart';
import 'link_call_diagnostics.dart';
import 'link_verification_log.dart';
import 'slot_ownership_store.dart';

abstract interface class LinkBackend {
  LinkVerifiedTarget get target;
  LinkOwnerReference get owner;
  Future<void> get disconnected;
  Future<Map<String, Object?>> call(String tool, Map<String, dynamic> arguments,
      {required Stream<void> cancelled, LinkCallTrace? diagnostic});
  Future<void> close();
}

/// The original adapter owns TLS and keys. This owner joins original process
/// and all three streams AND requires the adapter's bound settlement event.
final class LinkAdapterProcess implements LinkBackend {
  LinkAdapterProcess._(this._process, this.runId, this.resourceId, this.slotRef,
      this._proof, this._windows, this._verificationObserver) {
    _stderr = _readEvents().catchError(_streamFailed);
    _stdout = _readOutput().catchError(_streamFailed);
    unawaited(_process.stdin.done.then<void>((_) {
      _stdinDone = true;
      _endInput();
    }, onError: (Object error, StackTrace stack) {
      _streamFailed(error, stack);
      _endInput();
    }));
    _exit = _process.exitCode.whenComplete(() {
      _endInput();
      if (!_identity.isCompleted) {
        _identity.completeError(const LinkException('adapter_unavailable'));
      }
    }).onError((Object _, StackTrace __) => -1);
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
  final LinkVerificationObserver? _verificationObserver;
  final _output = StreamController<List<int>>.broadcast(sync: true);
  final _identity = Completer<LinkVerifiedTarget>();
  LinkOwnerReference? _owner;
  LinkVerifiedTarget? _target;
  LinkAppClient? _client;
  late final Future<void> _stdout, _stderr;
  late final Future<int> _exit;
  final _inputEnded = Completer<void>();
  Future<void>? _closing;
  bool _settledEvent = false, _failed = false, _stdinDone = false;
  bool _receiptFailureReported = false;
  int _diagnosticBytes = 0;
  static final _receiptFailure =
      RegExp(r'^\{"androidDevice":"unavailable","stage":"settlement-receipt",'
          r'"category":"(io|invalid_configuration)","code":(-\d{1,10})\}$');

  static Future<LinkAdapterProcess> start(LinkInstallation installation,
      {required String runId,
      required String resourceId,
      required bool proof,
      required Future<void> Function(LinkOwnerReference) acquired,
      LinkVerificationObserver? verificationObserver,
      Future<Process> Function(String, List<String>,
              {required bool runInShell, required String workingDirectory})?
          startProcess}) async {
    final executable = installation.adapterExecutable;
    final process = await (startProcess ?? Process.start)(
        executable,
        [
          proof ? '--link-proof' : '--link-business',
          runId,
          resourceId,
          '--current-user-cng-import'
        ],
        runInShell: false,
        workingDirectory: File(executable).parent.path);
    final owned = LinkAdapterProcess._(process, runId, resourceId,
        installation.slotRef, proof, false, verificationObserver);
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
        if (owned._owner == null) linkFail();
        await acquired(owned._owner!);
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

  static Future<LinkVerifiedTarget> initialize(LinkInstallation installation,
      {required String runId,
      required String resourceId,
      void Function(String)? onFingerprint}) async {
    final slots = SlotOwnershipStore(installation);
    final existing = await slots.file('device.dpapi').exists();
    if (existing) {
      // A prior TLS/key receipt without its original supervising owner's join
      // is UNKNOWN, not permission to rerun pairing or manufacture clean.
      await slots.locked(() async {
        await slots.requireNoUnsettledFiles();
        await slots.registeredPairing();
      });
    }
    final result = await superviseInitialization(installation,
        runId: runId, resourceId: resourceId, onFingerprint: onFingerprint);
    if (!existing) {
      await slots.publishInitializationJoin(result.owner, result.target);
    }
    return result.target;
  }

  /// Captures only the original process object and joins its actual streams.
  static Future<LinkInitializationSupervision> superviseInitialization(
      LinkInstallation installation,
      {required String runId,
      required String resourceId,
      String action = '--link-pair',
      void Function(String)? onFingerprint,
      Future<Process> Function(String, List<String>,
              {required bool runInShell, required String workingDirectory})?
          startProcess}) async {
    if (!{'--link-pair', '--register-pair', '--link-inspect-registration'}
        .contains(action)) {
      linkFail();
    }
    final process = await (startProcess ?? Process.start)(
        installation.adapterExecutable,
        [action, runId, resourceId, '--current-user-cng-import'],
        runInShell: false,
        workingDirectory: File(installation.adapterExecutable).parent.path);
    LinkVerifiedTarget? verified;
    LinkOwnerReference? originalOwner;
    var failed = false;
    var fingerprintDisplayed = false;
    Future<void> drain(Stream<List<int>> stream, bool events) async {
      var count = 0;
      final bytes = <int>[];
      await for (final chunk in stream) {
        count += chunk.length;
        if (count > 32768) {
          failed = true;
          continue;
        }
        bytes.addAll(chunk);
        if (!events && !fingerprintDisplayed && bytes.contains(10)) {
          try {
            // Original comparison display in the independent local console.
            final complete = bytes.sublist(0, bytes.lastIndexOf(10));
            for (final line in utf8.decode(complete).split('\n')) {
              if (!line.startsWith('{')) continue;
              final value = jsonDecode(line);
              if (value is Map &&
                  value['stage'] == 'verified-offer' &&
                  value['clientCertificateDigest'] is String &&
                  RegExp(r'^[a-f0-9]{64}$')
                      .hasMatch(value['clientCertificateDigest'] as String)) {
                stderr.writeln(
                    'pairing_client_fingerprint:${value['clientCertificateDigest']}');
                onFingerprint?.call(value['clientCertificateDigest'] as String);
                fingerprintDisplayed = true;
              }
            }
          } catch (_) {
            failed = true;
          }
        }
      }
      if (failed) return;
      for (final line in utf8.decode(bytes).split('\n')) {
        if (!events || !line.startsWith('SHIROHA_LINK_EVENT ')) continue;
        final value = boundedJsonObject(
            Uint8List.fromList(utf8.encode(line.substring(19).trim())),
            maxBytes: 4096);
        if (value['type'] == 'owner') {
          linkFields(value, {
            'type',
            'runId',
            'resourceId',
            'processId',
            'processStarted',
            'slotRef'
          });
          if (originalOwner != null ||
              value['runId'] != runId ||
              value['resourceId'] != resourceId ||
              value['processId'] != process.pid ||
              value['slotRef'] != installation.slotRef) {
            linkFail();
          }
          originalOwner =
              LinkOwnerReference.fromJson({...value}..remove('type'));
          continue;
        }
        if (value['type'] != 'initialization-complete') continue;
        linkFields(value, {'type', 'runId', 'resourceId', 'target'});
        if (verified != null ||
            originalOwner == null ||
            value['runId'] != runId ||
            value['resourceId'] != resourceId) {
          linkFail();
        }
        verified = LinkVerifiedTarget.fromJson(
            value['target'] as Map<String, dynamic>);
      }
    }

    // Original process and both streams are joined before any owner publication.
    final streams =
        Future.wait([drain(process.stdout, false), drain(process.stderr, true)])
            .then((_) {}, onError: (Object _, StackTrace __) {
      failed = true;
    });
    try {
      await process.stdin.close();
    } catch (_) {
      failed = true;
    }
    final code = await process.exitCode;
    await streams;
    if (code != 0 || failed || verified == null || originalOwner == null) {
      linkFail('initialization_incomplete');
    }
    return LinkInitializationSupervision(verified!, originalOwner!);
  }

  @override
  LinkVerifiedTarget get target =>
      _target ?? (throw const LinkException('unavailable'));
  @override
  LinkOwnerReference get owner =>
      _owner ?? (throw const LinkException('unavailable'));
  @override
  Future<void> get disconnected => _exit.then((_) {});

  void _streamFailed(Object _, StackTrace __) => _failed = true;

  void _endInput() {
    if (!_inputEnded.isCompleted) _inputEnded.complete();
  }

  Future<void> _closeInput() async {
    final input = _process.stdin;
    if (_proof) {
      // No SDK writer is created for proof. Only the original EOF is owed.
      await input.close();
      return;
    }
    try {
      // Dart destroys the process pipe on exit. A flush started before or
      // after that destruction can wait forever. Only flush itself is proof.
      final flushed = !_inputEnded.isCompleted &&
          await Future.any([
            input.flush().then((_) => true),
            _inputEnded.future.then((_) => false),
          ]);
      if (!flushed) _failed = true;
    } finally {
      // Exit can also interrupt a pending close. Observe the original sink's
      // done independently; exit alone never satisfies the final input check.
      await Future.any<void>([input.close(), _inputEnded.future]);
    }
  }

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
      if (!_windows && !_receiptFailureReported) {
        final failure = _receiptFailure.firstMatch(line);
        final code = int.tryParse(failure?.group(2) ?? '');
        if (failure != null &&
            code != null &&
            code >= -0x80000000 &&
            code < 0) {
          _receiptFailureReported = true;
          final hresult = code.toUnsigned(32).toRadixString(16).padLeft(8, '0');
          try {
            stderr.writeln('android_adapter_settlement_receipt_failed '
                'pid=${_process.pid} category=${failure.group(1)} '
                'hresult=0x$hresult');
          } catch (_) {/* Diagnostic output cannot affect settlement. */}
        }
      }
      return;
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
      {required Stream<void> cancelled, LinkCallTrace? diagnostic}) async {
    if (_closing != null || _failed || _client == null) linkFail('unavailable');
    final result = await _client!
        .call(tool, arguments, cancelled: cancelled, diagnostic: diagnostic);
    final source = result['source'];
    if (source is! Map ||
        source['kind'] != (_windows ? 'windows' : 'android') ||
        source['deviceRef'] != (_windows ? 'local' : target.deviceIdentity)) {
      diagnostic?.stage(LinkCallStage.resultValidate, LinkCallOutcome.rejected,
          LinkCallCause.deviceMismatch);
      linkFail('device_mismatch');
    }
    return result;
  }

  @override
  Future<void> close() => _closing ??= () async {
        // SDK close would abort request handlers. The owning Link first joins its
        // original call; EOF now requests the adapter's graceful target CLOSE.
        try {
          await _closeInput();
        } catch (_) {
          _failed = true;
        }
        final status = await _exit;
        await Future.wait([_stdout, _stderr]);
        try {
          await _client?.close();
        } catch (_) {
          _failed = true;
        }
        if (status != 0 || !_stdinDone || !_settledEvent || _failed) {
          linkFail('owner_unsettled');
        }
        observeLinkVerification(
            _verificationObserver,
            () => LinkVerificationObservation.adapterJoined(owner,
                proof: _proof, processExitCode: status));
      }();
}

final class LinkInitializationSupervision {
  const LinkInitializationSupervision(this.target, this.owner);
  final LinkVerifiedTarget target;
  final LinkOwnerReference owner;
}
