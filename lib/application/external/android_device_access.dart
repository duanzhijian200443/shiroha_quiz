import 'android_foreground_access.dart';
import '../capabilities/capability.dart';
import 'external_authorization.dart';
import 'first_party_stage_approval.dart';

/// Initial policy for the bounded Android question READ consumer.
/// Saved generation consent is absent because this consumer grants no STAGE.
ExternalGrantPolicy androidQuestionReadPolicy() => ExternalGrantPolicy(
      permissions: const [CapabilityPermission.read],
      scopes: const [],
      categories: const [ExternalContentCategory.questionContent],
      allContent: true,
    );

/// First-party local control. Neither the UI nor a wire DTO supplies evidence.
abstract interface class AndroidDeviceAccess {
  AndroidDeviceAccessState get state;
  Stream<void> get changes;
  Future<void> inspect();
  Future<void> pair();
  void confirmPairing();
  Future<void> enable();
  Future<void> disable();
  Future<void> setGenerationMode(ExternalGenerationMode? mode);
  FirstPartyStageApprovalView? openStageApprovalView();
  Future<void> cancelPending();
  Future<void> observeFlutter(bool resumed);
  Future<void> close();
}

final class AndroidDeviceAccessState {
  const AndroidDeviceAccessState(
      {this.available = false,
      this.phase = AndroidAccessPhase.off,
      this.address,
      this.deviceId,
      this.certificateDigest,
      this.profileId,
      this.clientDigest,
      this.expiresAt,
      this.paired = false,
      this.listening = false,
      this.connected = false,
      this.awaitingConfirmation = false,
      this.policyReady = false,
      this.policyChanging = false,
      this.generationMode,
      this.error});
  final bool available, paired, awaitingConfirmation, listening, connected;
  final bool policyReady, policyChanging;

  /// Null means the current grant has no complete generation permission.
  final ExternalGenerationMode? generationMode;
  final AndroidAccessPhase phase;
  final String? address,
      deviceId,
      certificateDigest,
      profileId,
      clientDigest,
      error;
  final DateTime? expiresAt;
}
