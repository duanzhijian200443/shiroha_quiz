import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:shiroha_quiz/services/backup/sha256.dart';

import 'train_c_evidence_probe.dart';

const trainCLiveAttemptCapabilityEnvironment =
    'TRAIN_C_LIVE_ATTEMPT_CAPABILITY';

/// The single durable control-plane phase for TRAIN C L1B.
enum TrainCLiveRunPhase {
  prepared,
  configured,
  parseRunning,
  pendingReview,
  commitReady,
  committed,
  restartProved,
  b0Exported,
  b0Restored,
  finalized,
  failedConsumed,
}

extension TrainCLiveRunPhaseX on TrainCLiveRunPhase {
  String get wireName => switch (this) {
        TrainCLiveRunPhase.prepared => 'PREPARED',
        TrainCLiveRunPhase.configured => 'CONFIGURED',
        TrainCLiveRunPhase.parseRunning => 'PARSE_RUNNING',
        TrainCLiveRunPhase.pendingReview => 'PENDING_REVIEW',
        TrainCLiveRunPhase.commitReady => 'COMMIT_READY',
        TrainCLiveRunPhase.committed => 'COMMITTED',
        TrainCLiveRunPhase.restartProved => 'RESTART_PROVED',
        TrainCLiveRunPhase.b0Exported => 'B0_EXPORTED',
        TrainCLiveRunPhase.b0Restored => 'B0_RESTORED',
        TrainCLiveRunPhase.finalized => 'FINALIZED',
        TrainCLiveRunPhase.failedConsumed => 'FAILED_CONSUMED',
      };

  static TrainCLiveRunPhase parse(String value) {
    for (final phase in TrainCLiveRunPhase.values) {
      if (phase.wireName == value) return phase;
    }
    throw const TrainCEvidenceProbeException('TRAIN_C_HARNESS_NOT_READY');
  }
}

enum TrainCLiveRunAttemptState { authorizedUnused, consumed }

extension TrainCLiveRunAttemptStateX on TrainCLiveRunAttemptState {
  String get wireName => switch (this) {
        TrainCLiveRunAttemptState.authorizedUnused => 'AUTHORIZED_UNUSED',
        TrainCLiveRunAttemptState.consumed => 'CONSUMED',
      };

  static TrainCLiveRunAttemptState parse(String value) {
    for (final state in TrainCLiveRunAttemptState.values) {
      if (state.wireName == value) return state;
    }
    throw const TrainCEvidenceProbeException('TRAIN_C_HARNESS_NOT_READY');
  }
}

/// Safe view of the durable control artifact. It never exposes a runtime
/// path or the opaque runtime reattach capability.
final class TrainCLiveRunCapabilitySnapshot {
  const TrainCLiveRunCapabilitySnapshot({
    required this.runNumber,
    required this.approvedHarnessHead,
    required this.approvedBase,
    required this.runtimeIdentity,
    required this.attemptState,
    required this.phase,
    required this.revision,
  });

  final int runNumber;
  final String approvedHarnessHead;
  final String approvedBase;
  final String? runtimeIdentity;
  final TrainCLiveRunAttemptState attemptState;
  final TrainCLiveRunPhase phase;
  final int revision;

  bool get runtimeBound => runtimeIdentity != null;

  Map<String, Object?> toSafeMap() => <String, Object?>{
        'runNumber': runNumber,
        'attemptState': attemptState.wireName,
        'phase': phase.wireName,
        'revision': revision,
        'runtimeIdentityPreserved': runtimeBound,
        'approvedHeadPresent': approvedHarnessHead.isNotEmpty,
        'approvedBasePresent': approvedBase.isNotEmpty,
      };
}

/// Unified durable authority for one TRAIN C Run #1.
///
/// State is an append-only sequence of immutable revision records. Each new
/// record is published by exclusive creation while holding an OS file lock,
/// so phases and attempt consumption share one CAS-protected artifact. The
/// raw runtime capability stays only in this repo-external control artifact;
/// public status exposes only its digest/presence.
final class TrainCLiveRunCapability {
  TrainCLiveRunCapability._(this._stateDirectory, this._nonce);

  static const _schemaVersion = 2;
  static const _statePrefix = 'run_capability.';
  static const _stateSuffix = '.json';
  static const _lockName = '.run_capability.lock';

  final Directory _stateDirectory;
  final String _nonce;
  String? _verifiedHead;
  String? _verifiedBase;

  File get _lockFile => File(
        '${_stateDirectory.path}${Platform.pathSeparator}$_lockName',
      );

  /// Creates the only authorization record for a new Run #1. The isolated
  /// runtime is bound later in the same artifact, before parse may begin.
  static String authorize({
    required Directory stateDirectory,
    required String approvedHarnessHead,
    required String approvedBase,
  }) {
    if (!_isSha(approvedHarnessHead) || !_isSha(approvedBase)) {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_CODE_IDENTITY_MISMATCH',
      );
    }
    stateDirectory.createSync(recursive: true);
    if (stateDirectory.listSync().isNotEmpty) {
      throw const TrainCEvidenceProbeException('TRAIN_C_ISOLATION_FAILURE');
    }
    final nonce = _nonceValue();
    final authority = TrainCLiveRunCapability._(stateDirectory, nonce);
    authority._writeInitialState(
      approvedHarnessHead: approvedHarnessHead,
      approvedBase: approvedBase,
    );
    return _encodeCapability(stateDirectory.path, nonce);
  }

  static TrainCLiveRunCapability fromCapability(String capability) {
    try {
      final decoded = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(capability))),
      );
      if (decoded is! Map ||
          decoded['directory'] is! String ||
          decoded['nonce'] is! String) {
        throw const FormatException();
      }
      final directory = Directory(decoded['directory'] as String);
      final nonce = decoded['nonce'] as String;
      if (!directory.isAbsolute || nonce.trim().isEmpty) {
        throw const FormatException();
      }
      final authority = TrainCLiveRunCapability._(directory, nonce);
      final state = authority._readCurrentState();
      authority._validateState(state);
      if (state['nonceDigest'] != _digest(nonce)) {
        throw const FormatException();
      }
      return authority;
    } catch (error) {
      if (error is TrainCEvidenceProbeException) rethrow;
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_PROVIDER_ENVIRONMENT_BLOCKED',
      );
    }
  }

  TrainCLiveRunCapabilitySnapshot get snapshot {
    final state = _readCurrentState();
    _validateState(state);
    return _snapshot(state);
  }

  /// Internal-only reattach token. It must never be printed or put in final
  /// evidence; the control artifact itself is repo-external and private.
  String get runtimeCapabilityForReattach {
    final value = _readCurrentState()['runtimeCapability'];
    if (value is! String || value.trim().isEmpty) {
      throw const TrainCEvidenceProbeException('TRAIN_C_RUNTIME_NOT_BOUND');
    }
    return value;
  }

  void verifyUnused({
    required String reviewedHarnessHead,
    String? reviewedBase,
  }) {
    final state = _readCurrentState();
    _validateState(state);
    _verifyReviewedIdentity(
      state,
      reviewedHarnessHead,
      reviewedBase ?? state['approvedBase'] as String,
    );
    final attempt = TrainCLiveRunAttemptStateX.parse(
      state['attemptState'] as String,
    );
    final phase = TrainCLiveRunPhaseX.parse(state['phase'] as String);
    if (attempt == TrainCLiveRunAttemptState.consumed ||
        phase == TrainCLiveRunPhase.failedConsumed ||
        phase.index > TrainCLiveRunPhase.parseRunning.index) {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_ATTEMPT_BUDGET_EXHAUSTED',
      );
    }
  }

  void verifyContinuation({
    required String reviewedHarnessHead,
    String? reviewedBase,
  }) {
    final state = _readCurrentState();
    _validateState(state);
    _verifyReviewedIdentity(
      state,
      reviewedHarnessHead,
      reviewedBase ?? state['approvedBase'] as String,
    );
    final attempt = TrainCLiveRunAttemptStateX.parse(
      state['attemptState'] as String,
    );
    final phase = TrainCLiveRunPhaseX.parse(state['phase'] as String);
    if (attempt != TrainCLiveRunAttemptState.consumed ||
        !_continuationPhase(phase) ||
        state['runtimeCapability'] is! String ||
        state['runtimeIdentity'] is! String) {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_PROVIDER_ENVIRONMENT_BLOCKED',
      );
    }
  }

  void bindRuntimeCapability(String runtimeCapability) {
    final trimmed = runtimeCapability.trim();
    if (trimmed.isEmpty) {
      throw const TrainCEvidenceProbeException('TRAIN_C_RUNTIME_NOT_BOUND');
    }
    _mutate((state) {
      _requireVerifiedIdentity(state);
      final phase = TrainCLiveRunPhaseX.parse(state['phase'] as String);
      if (phase != TrainCLiveRunPhase.prepared ||
          state['runtimeCapability'] != null ||
          state['runtimeIdentity'] != null) {
        throw const TrainCEvidenceProbeException('TRAIN_C_HEAD_DRIFT');
      }
      state['runtimeCapability'] = trimmed;
      state['runtimeIdentity'] = _digest(trimmed);
      return state;
    });
  }

  bool runtimeMatches(String runtimeCapability) {
    final state = _readCurrentState();
    _validateState(state);
    return state['runtimeIdentity'] == _digest(runtimeCapability.trim());
  }

  /// Atomically consumes Run #1 immediately before a wrapped request is
  /// delegated to dart:io. A failure here prevents network dispatch.
  void consumeAtDispatch() {
    _mutate((state) {
      _requireVerifiedIdentity(state);
      final attempt = TrainCLiveRunAttemptStateX.parse(
        state['attemptState'] as String,
      );
      final phase = TrainCLiveRunPhaseX.parse(state['phase'] as String);
      if (attempt == TrainCLiveRunAttemptState.consumed) {
        throw const TrainCEvidenceProbeException(
          'TRAIN_C_ATTEMPT_BUDGET_EXHAUSTED',
        );
      }
      if (phase != TrainCLiveRunPhase.parseRunning) {
        throw const TrainCEvidenceProbeException(
          'TRAIN_C_PROVIDER_ENVIRONMENT_BLOCKED',
        );
      }
      state['attemptState'] = TrainCLiveRunAttemptState.consumed.wireName;
      return state;
    });
  }

  void assertParseAllowed() {
    final state = _readCurrentState();
    _validateState(state);
    _requireVerifiedIdentity(state);
    final attempt = TrainCLiveRunAttemptStateX.parse(
      state['attemptState'] as String,
    );
    final phase = TrainCLiveRunPhaseX.parse(state['phase'] as String);
    if (attempt != TrainCLiveRunAttemptState.authorizedUnused ||
        state['runtimeCapability'] is! String ||
        (phase != TrainCLiveRunPhase.configured &&
            phase != TrainCLiveRunPhase.parseRunning)) {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_ATTEMPT_BUDGET_EXHAUSTED',
      );
    }
  }

  void transitionTo(
    TrainCLiveRunPhase next, {
    int? expectedRevision,
  }) {
    _mutate((state) {
      _requireVerifiedIdentity(state);
      final current = TrainCLiveRunPhaseX.parse(state['phase'] as String);
      final attempt = TrainCLiveRunAttemptStateX.parse(
        state['attemptState'] as String,
      );
      if (!_legalTransition(current, next) ||
          (next == TrainCLiveRunPhase.failedConsumed &&
              attempt != TrainCLiveRunAttemptState.consumed)) {
        throw const TrainCEvidenceProbeException('TRAIN_C_HARNESS_NOT_READY');
      }
      if (next != TrainCLiveRunPhase.prepared &&
          state['runtimeCapability'] is! String) {
        throw const TrainCEvidenceProbeException('TRAIN_C_RUNTIME_NOT_BOUND');
      }
      state['phase'] = next.wireName;
      return state;
    }, expectedRevision: expectedRevision);
  }

  void markConfigured() => transitionTo(TrainCLiveRunPhase.configured);

  void markParseRunning() {
    final phase = snapshot.phase;
    if (phase == TrainCLiveRunPhase.parseRunning) {
      assertParseAllowed();
      return;
    }
    transitionTo(TrainCLiveRunPhase.parseRunning);
  }

  void markPendingReview() => transitionTo(TrainCLiveRunPhase.pendingReview);

  void markFailedConsumed() => transitionTo(TrainCLiveRunPhase.failedConsumed);

  void requireProviderForbidden() {
    if (!_continuationPhase(snapshot.phase)) {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_PROVIDER_ENVIRONMENT_BLOCKED',
      );
    }
  }

  void validateRestoreRuntimeIdentity(String restoreRuntimeCapability) {
    final trimmed = restoreRuntimeCapability.trim();
    if (trimmed.isEmpty || runtimeMatches(trimmed)) {
      throw const TrainCEvidenceProbeException('TRAIN_C_ISOLATION_FAILURE');
    }
  }

  Map<String, Object?> safeStatus({
    String? reviewedHarnessHead,
    String? reviewedBase,
  }) {
    final current = snapshot;
    return <String, Object?>{
      ...current.toSafeMap(),
      'approvedHeadMatches': reviewedHarnessHead != null &&
          current.approvedHarnessHead == reviewedHarnessHead,
      'approvedBaseMatches':
          reviewedBase != null && current.approvedBase == reviewedBase,
    };
  }

  void _writeInitialState({
    required String approvedHarnessHead,
    required String approvedBase,
  }) {
    _stateDirectory.createSync(recursive: true);
    _writeRevision(<String, Object?>{
      'schemaVersion': _schemaVersion,
      'runNumber': 1,
      'approvedHarnessHead': approvedHarnessHead,
      'approvedBase': approvedBase,
      'approvedProductionBase': '711fd33f564b9fb6bb3c992d6458b0075990646c',
      'nonceDigest': _digest(_nonce),
      'runtimeCapability': null,
      'runtimeIdentity': null,
      'attemptState': TrainCLiveRunAttemptState.authorizedUnused.wireName,
      'phase': TrainCLiveRunPhase.prepared.wireName,
      'revision': 0,
      'updatedAtEpochMs': DateTime.now().millisecondsSinceEpoch,
    }, initial: true);
  }

  Map<String, Object?> _mutate(
    Map<String, Object?> Function(Map<String, Object?> state) update, {
    int? expectedRevision,
  }) {
    final lock = _lockFile.openSync(mode: FileMode.writeOnlyAppend);
    try {
      lock.lockSync(FileLock.blockingExclusive);
      final current = _readCurrentState();
      _validateState(current);
      final currentRevision = current['revision'] as int;
      if (expectedRevision != null && expectedRevision != currentRevision) {
        throw const TrainCEvidenceProbeException('TRAIN_C_STALE_STATE');
      }
      final next = update(Map<String, Object?>.from(current));
      next['revision'] = currentRevision + 1;
      next['updatedAtEpochMs'] = DateTime.now().millisecondsSinceEpoch;
      _validateState(next);
      _writeRevision(next);
      return next;
    } finally {
      try {
        lock.unlockSync();
      } finally {
        lock.closeSync();
      }
    }
  }

  void _writeRevision(
    Map<String, Object?> state, {
    bool initial = false,
  }) {
    final revision = state['revision'];
    if (revision is! int || revision < 0) {
      throw const TrainCEvidenceProbeException('TRAIN_C_HARNESS_NOT_READY');
    }
    final file = File(
      '${_stateDirectory.path}${Platform.pathSeparator}$_statePrefix$revision$_stateSuffix',
    );
    final temporaryFile = File(
      '${file.path}.${_digest(_nonce).substring(0, 16)}.tmp',
    );
    var published = false;
    try {
      temporaryFile.createSync(exclusive: true);
      temporaryFile.writeAsStringSync(jsonEncode(state), flush: true);
      // Publish only after the complete JSON record is durable in the same
      // directory. Readers therefore observe either the previous immutable
      // revision or this complete new revision, never a partial file.
      temporaryFile.renameSync(file.path);
      published = true;
    } on FileSystemException {
      throw const TrainCEvidenceProbeException('TRAIN_C_STALE_STATE');
    } catch (_) {
      if (initial) rethrow;
      throw const TrainCEvidenceProbeException('TRAIN_C_HARNESS_NOT_READY');
    } finally {
      if (!published && temporaryFile.existsSync()) {
        try {
          temporaryFile.deleteSync();
        } catch (_) {
          // The state directory is private and a failed publication remains
          // fail-closed; cleanup is only best effort.
        }
      }
    }
  }

  Map<String, Object?> _readCurrentState() {
    try {
      final candidates = <(int, File)>[];
      if (!_stateDirectory.existsSync()) throw const FormatException();
      for (final entity in _stateDirectory.listSync(followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!name.startsWith(_statePrefix) || !name.endsWith(_stateSuffix)) {
          continue;
        }
        final rawRevision = name.substring(
          _statePrefix.length,
          name.length - _stateSuffix.length,
        );
        final revision = int.tryParse(rawRevision);
        if (revision != null && revision >= 0) {
          candidates.add((revision, entity));
        }
      }
      if (candidates.isEmpty) throw const FormatException();
      candidates.sort((left, right) => left.$1.compareTo(right.$1));
      final decoded = jsonDecode(candidates.last.$2.readAsStringSync());
      if (decoded is! Map) throw const FormatException();
      return Map<String, Object?>.from(decoded);
    } catch (error) {
      if (error is TrainCEvidenceProbeException) rethrow;
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_PROVIDER_ENVIRONMENT_BLOCKED',
      );
    }
  }

  void _validateState(Map<String, Object?> state) {
    if (state['schemaVersion'] != _schemaVersion ||
        state['runNumber'] != 1 ||
        state['approvedHarnessHead'] is! String ||
        state['approvedBase'] is! String ||
        state['approvedProductionBase'] is! String ||
        state['nonceDigest'] != _digest(_nonce) ||
        (state['runtimeCapability'] != null &&
            state['runtimeCapability'] is! String) ||
        (state['runtimeIdentity'] != null &&
            !_isSha256(state['runtimeIdentity'] as String)) ||
        state['attemptState'] is! String ||
        state['phase'] is! String ||
        state['revision'] is! int ||
        (state['revision'] as int) < 0) {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_PROVIDER_ENVIRONMENT_BLOCKED',
      );
    }
    if (!_isSha(state['approvedHarnessHead'] as String) ||
        !_isSha(state['approvedBase'] as String) ||
        !_isSha(state['approvedProductionBase'] as String)) {
      throw const TrainCEvidenceProbeException(
        'TRAIN_C_CODE_IDENTITY_MISMATCH',
      );
    }
    TrainCLiveRunAttemptStateX.parse(state['attemptState'] as String);
    TrainCLiveRunPhaseX.parse(state['phase'] as String);
  }

  TrainCLiveRunCapabilitySnapshot _snapshot(Map<String, Object?> state) {
    return TrainCLiveRunCapabilitySnapshot(
      runNumber: state['runNumber'] as int,
      approvedHarnessHead: state['approvedHarnessHead'] as String,
      approvedBase: state['approvedBase'] as String,
      runtimeIdentity: state['runtimeIdentity'] as String?,
      attemptState: TrainCLiveRunAttemptStateX.parse(
        state['attemptState'] as String,
      ),
      phase: TrainCLiveRunPhaseX.parse(state['phase'] as String),
      revision: state['revision'] as int,
    );
  }

  void _verifyReviewedIdentity(
    Map<String, Object?> state,
    String reviewedHarnessHead,
    String reviewedBase,
  ) {
    if (state['approvedHarnessHead'] != reviewedHarnessHead ||
        state['approvedBase'] != reviewedBase) {
      throw const TrainCEvidenceProbeException('TRAIN_C_HEAD_DRIFT');
    }
    _verifiedHead = reviewedHarnessHead;
    _verifiedBase = reviewedBase;
  }

  void _requireVerifiedIdentity(Map<String, Object?> state) {
    if (_verifiedHead == null ||
        _verifiedBase == null ||
        state['approvedHarnessHead'] != _verifiedHead ||
        state['approvedBase'] != _verifiedBase) {
      throw const TrainCEvidenceProbeException('TRAIN_C_HEAD_DRIFT');
    }
  }

  static bool _legalTransition(
    TrainCLiveRunPhase current,
    TrainCLiveRunPhase next,
  ) {
    return switch ((current, next)) {
      (TrainCLiveRunPhase.prepared, TrainCLiveRunPhase.configured) => true,
      (TrainCLiveRunPhase.configured, TrainCLiveRunPhase.parseRunning) => true,
      (TrainCLiveRunPhase.parseRunning, TrainCLiveRunPhase.pendingReview) =>
        true,
      (TrainCLiveRunPhase.parseRunning, TrainCLiveRunPhase.failedConsumed) =>
        true,
      (TrainCLiveRunPhase.pendingReview, TrainCLiveRunPhase.commitReady) =>
        true,
      (TrainCLiveRunPhase.commitReady, TrainCLiveRunPhase.committed) => true,
      (TrainCLiveRunPhase.committed, TrainCLiveRunPhase.restartProved) => true,
      (TrainCLiveRunPhase.restartProved, TrainCLiveRunPhase.b0Exported) => true,
      (TrainCLiveRunPhase.b0Exported, TrainCLiveRunPhase.b0Restored) => true,
      (TrainCLiveRunPhase.b0Restored, TrainCLiveRunPhase.finalized) => true,
      _ => false,
    };
  }

  static bool _continuationPhase(TrainCLiveRunPhase phase) {
    return phase == TrainCLiveRunPhase.pendingReview ||
        phase == TrainCLiveRunPhase.commitReady ||
        phase == TrainCLiveRunPhase.committed ||
        phase == TrainCLiveRunPhase.restartProved ||
        phase == TrainCLiveRunPhase.b0Exported ||
        phase == TrainCLiveRunPhase.b0Restored;
  }

  static String _encodeCapability(String directory, String nonce) {
    return base64Url.encode(
      utf8.encode(jsonEncode(<String, String>{
        'directory': directory,
        'nonce': nonce,
      })),
    );
  }

  static String _nonceValue() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes);
  }

  static String _digest(String value) => sha256Hex(utf8.encode(value));

  static bool _isSha(String value) => RegExp(r'^[0-9a-f]{40}$').hasMatch(value);

  static bool _isSha256(String value) =>
      RegExp(r'^[0-9a-f]{64}$').hasMatch(value);
}

/// Compatibility alias for the previously landed mechanical API. It refers
/// to the unified capability above; no second attempt marker exists.
typedef TrainCLiveAttemptAuthority = TrainCLiveRunCapability;
