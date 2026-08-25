import 'train_c_evidence_probe.dart';
import 'train_c_isolated_runtime.dart';
import 'train_c_live_attempt_authority.dart';

/// Bounded control-plane facade for the TRAIN C L1B process chain.
///
/// The controller owns only durable identity, phase transitions and runtime
/// reattachment. Production composition remains responsible for proving the
/// actual pending-review, commit, render and B0 facts before asking the
/// controller to advance. This class never writes questions, runs SQL,
/// invokes a provider or manufactures acceptance evidence.
final class TrainCL1BPhaseController {
  TrainCL1BPhaseController._(this.capability);

  final TrainCLiveRunCapability capability;

  static TrainCL1BPhaseController forLive({
    required TrainCLiveRunCapability capability,
    required String reviewedHarnessHead,
    required String reviewedBase,
  }) {
    capability.verifyUnused(
      reviewedHarnessHead: reviewedHarnessHead,
      reviewedBase: reviewedBase,
    );
    final controller = TrainCL1BPhaseController._(capability);
    // PREPARED is the only phase before the first process has created and
    // bound its isolated runtime. Later live launches must already be bound.
    if (controller.status.phase != TrainCLiveRunPhase.prepared ||
        controller.status.runtimeBound) {
      controller.requireParseLaunch();
    }
    return controller;
  }

  static TrainCL1BPhaseController forContinuation({
    required TrainCLiveRunCapability capability,
    required String reviewedHarnessHead,
    required String reviewedBase,
  }) {
    capability.verifyContinuation(
      reviewedHarnessHead: reviewedHarnessHead,
      reviewedBase: reviewedBase,
    );
    return TrainCL1BPhaseController._(capability);
  }

  TrainCLiveRunCapabilitySnapshot get status => capability.snapshot;

  /// Creates the sole runtime for a PREPARED capability, or reattaches the
  /// already-bound runtime for every later process. A continuation can never
  /// silently create a new runtime.
  Future<TrainCIsolatedRuntime> createOrReattachRuntime() async {
    final current = capability.snapshot;
    if (current.runtimeBound) {
      return reattachRuntime();
    }
    if (current.phase != TrainCLiveRunPhase.prepared) {
      throw const TrainCEvidenceProbeException('TRAIN_C_RUNTIME_NOT_BOUND');
    }
    final runtime = await TrainCIsolatedRuntime.create();
    try {
      await runtime.open();
      final runtimeCapability =
          await runtime.issuePersistentReattachCapability();
      capability.bindRuntimeCapability(runtimeCapability);
      return runtime;
    } catch (_) {
      await runtime.dispose();
      rethrow;
    }
  }

  /// Reattaches the exact runtime token stored in the unified control
  /// artifact. The returned composition is safe to use only in the current
  /// phase; callers must still install provider-disabled policy for
  /// continuation phases.
  Future<TrainCIsolatedRuntime> reattachRuntime() async {
    final runtimeCapability = capability.runtimeCapabilityForReattach;
    if (!capability.runtimeMatches(runtimeCapability)) {
      throw const TrainCEvidenceProbeException('TRAIN_C_HEAD_DRIFT');
    }
    try {
      return await TrainCIsolatedRuntime.reattachFromCapability(
        runtimeCapability,
        deleteRootOnDispose: false,
      );
    } on TrainCIsolationException {
      rethrow;
    } catch (_) {
      throw const TrainCEvidenceProbeException('TRAIN_C_RUNTIME_NOT_BOUND');
    }
  }

  void requireParseLaunch() {
    capability.assertParseAllowed();
  }

  void markConfigured() => capability.markConfigured();

  void markParseRunning() => capability.markParseRunning();

  void markPendingReview() => capability.markPendingReview();

  void markCommitReady() =>
      capability.transitionTo(TrainCLiveRunPhase.commitReady);

  void markCommitted() => capability.transitionTo(TrainCLiveRunPhase.committed);

  void markRestartProved() =>
      capability.transitionTo(TrainCLiveRunPhase.restartProved);

  void markB0Exported() =>
      capability.transitionTo(TrainCLiveRunPhase.b0Exported);

  void markB0Restored() =>
      capability.transitionTo(TrainCLiveRunPhase.b0Restored);

  void markFinalized() => capability.transitionTo(TrainCLiveRunPhase.finalized);

  void markFailedConsumed() => capability.markFailedConsumed();

  void transitionTo(
    TrainCLiveRunPhase next, {
    int? expectedRevision,
  }) =>
      capability.transitionTo(next, expectedRevision: expectedRevision);

  void validateRestoreRuntimeIdentity(String restoreRuntimeCapability) =>
      capability.validateRestoreRuntimeIdentity(restoreRuntimeCapability);

  void requireProviderForbidden() => capability.requireProviderForbidden();

  Map<String, Object?> safeStatus({
    required String reviewedHarnessHead,
    required String reviewedBase,
  }) =>
      capability.safeStatus(
        reviewedHarnessHead: reviewedHarnessHead,
        reviewedBase: reviewedBase,
      );
}
