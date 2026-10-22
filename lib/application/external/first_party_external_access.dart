import 'dart:async';

import '../backup/backup_restore_gate.dart';
import '../generated_question/generated_local_authority.dart';
import 'external_authorization.dart';
import 'external_generated_stage.dart';
import 'external_trust_coordinator.dart';
import 'external_trust_core.dart';
import 'first_party_external_credentials.dart';
import 'first_party_stage_approval.dart';
import 'local_authorization_service.dart';

/// Safe local UI state. Policy selection is never evidence of a connection.
final class FirstPartyExternalStatus {
  const FirstPartyExternalStatus(
      {this.profileId,
      this.pairing,
      this.pairingAvailable = false,
      this.pairingDisplay,
      this.pairingFailed = false,
      this.connected = false,
      this.enabled = false,
      this.expiresAt,
      this.approvedTargets = 0});
  final String? profileId;
  final PairingState? pairing;
  final bool pairingAvailable, pairingFailed;
  final FirstPartyPairingDisplay? pairingDisplay;
  final bool connected, enabled;
  final DateTime? expiresAt;
  final int approvedTargets;
}

/// Supplied only by trusted composition after transport/credential admission.
/// The attempt is opaque and reauthenticated for each local control operation.
/// This object implements no identity, policy, pairing or persistence authority.
final class FirstPartyExternalBinding {
  const FirstPartyExternalBinding(
      {required this.management,
      required this.coordinator,
      required this.trust,
      required this.stages,
      required this.localOwner,
      required this.authenticationAttempt,
      this.credentials,
      this.stageApproval,
      required this.publishApprovals,
      required this.shutdown});
  final ExternalAuthorizationManagement management;
  final ExternalTrustCoordinator coordinator;
  final ExternalTrustCore trust;
  final ExternalGeneratedStageService stages;
  final GeneratedLocalAuthoritySession localOwner;
  final Object? Function() authenticationAttempt;
  final FirstPartyCredentialServices? credentials;
  final FirstPartyStageApproval? stageApproval;
  final void Function(List<ExternalStageContext>) publishApprovals;
  final Future<void> Function() shutdown;
}

/// First-party control only; never registered as a Capability or MCP tool.
final class FirstPartyExternalAccess {
  FirstPartyExternalAccess(
      {required this.policy, required bool Function() compositionIsCurrent})
      : _isCurrent = compositionIsCurrent;
  final LocalAuthorizationService policy;
  final bool Function() _isCurrent;
  FirstPartyExternalBinding? _binding;
  ExternalTrustProfile? _profile;
  String? _selectedId;
  ExternalSession? _session;
  FirstPartyCredentialConnection? _connection;
  FirstPartyPairingRequest? _pairingRequest;
  bool _pairingFailed = false;
  int? _sessionRevision;
  final _approvals = <ExternalStageContext>[];
  List<GeneratedReviewTargetChoice> _choices = const [];
  bool _closed = false, _busy = false;
  Completer<void>? _idle;
  Future<void>? _shutdown;
  bool get isCurrent =>
      !_closed &&
      _isCurrent() &&
      policy.isCurrent &&
      !BackupRestoreMutationGate.instance.isMaintenance;

  void _validate() {
    if (!isCurrent) externalAuthFail(ExternalAuthFailure.unauthorized);
  }

  /// No startup call installs this. UI cannot supply authentication evidence.
  void installTrusted(FirstPartyExternalBinding binding) {
    _validate();
    if (_binding != null || _busy) {
      externalAuthFail(ExternalAuthFailure.unauthorized);
    }
    if (binding.credentials != null &&
        !identical(binding.trust.credentials, binding.credentials!.boundary)) {
      externalAuthFail(ExternalAuthFailure.unauthorized);
    }
    _selectedId = null;
    _binding = binding;
  }

  Future<T> _run<T>(Future<T> Function() action) async {
    _validate();
    if (_busy) externalAuthFail(ExternalAuthFailure.unauthorized);
    _busy = true;
    _idle = Completer<void>();
    try {
      final result = await action();
      _validate();
      return result;
    } finally {
      _busy = false;
      _idle!.complete();
      _idle = null;
    }
  }

  Future<ExternalProfilePage> profiles({String? afterId}) => _run(() async {
        final view = policy.openView();
        try {
          return await view.profiles(afterId: afterId);
        } finally {
          view.close();
        }
      });

  void _forgetAccess() {
    _binding?.stageApproval?.cancel();
    final b = _binding;
    if (b != null &&
        _profile != null &&
        b.trust.snapshot(_profile!.principal).state ==
            PairingState.enabledForCurrentRuntime) {
      b.trust.disable(_profile!.principal);
    }
    _session = null;
    _connection = null;
    _sessionRevision = null;
    _choices = const [];
    _approvals.clear();
    _binding?.publishApprovals(const []);
  }

  Future<void> select(String profileId) => _run(() async {
        final b = _binding;
        _forgetAccess();
        _profile = null;
        _selectedId = null;
        _pairingRequest = null;
        if (b == null) {
          final view = policy.openView();
          try {
            await view.read(await view.select(profileId));
          } finally {
            view.close();
          }
        } else {
          final ref = await b.management.selectProfile(profileId);
          final selected = await b.coordinator.registerProfile(ref);
          _validate();
          _profile = selected;
        }
        _validate();
        _selectedId = profileId;
      });

  FirstPartyCredentialServices _credentials() {
    final services = _binding?.credentials;
    if (services == null || _profile == null || !services.boundary.isCurrent) {
      externalAuthFail(ExternalAuthFailure.unauthorized);
    }
    return services;
  }

  /// Requests pairing through the trusted credential owner.
  ///
  /// Request inputs and proofs come only from that owner.
  /// Selecting/editing a Profile never invokes this action.
  Future<void> requestPairing() => _run(() async {
        final services = _credentials();
        final b = _binding!;
        if (_pairingFailed ||
            b.trust.snapshot(_profile!.principal).state !=
                PairingState.unpaired) {
          externalAuthFail(ExternalAuthFailure.unauthorized);
        }
        try {
          final ref = await b.management.selectProfile(_selectedId!);
          _pairingRequest = await services.pairing.request(ref);
          _validate();
        } catch (_) {
          _pairingFailed = true;
          rethrow;
        }
      });

  Future<void> _pairingAction(bool complete) => _run(() async {
        _credentials();
        final request = _pairingRequest;
        final expected = complete
            ? PairingState.approvedPendingProof
            : PairingState.requestPending;
        if (request == null ||
            _pairingFailed ||
            _binding!.trust.snapshot(_profile!.principal).state != expected) {
          externalAuthFail(ExternalAuthFailure.unauthorized);
        }
        try {
          if (complete) {
            await request.complete();
          } else {
            await request.approve();
          }
        } catch (_) {
          // Preserve P0's actual pending state. Failed/unknown completion has no
          // automatic retry, reset, success projection or enablement.
          _pairingFailed = true;
          _forgetAccess();
          rethrow;
        }
      });

  Future<void> approvePairing() => _pairingAction(false);
  Future<void> completePairing() => _pairingAction(true);

  Object _authenticate(FirstPartyExternalBinding b) {
    _validate();
    final attempt = b.authenticationAttempt();
    if (attempt == null || _profile == null) {
      externalAuthFail(ExternalAuthFailure.unauthorized);
    }
    final peer = b.trust.authenticate(attempt);
    if (!identical(peer.principal, _profile!.principal) ||
        peer.generation != b.trust.generation) {
      externalAuthFail(ExternalAuthFailure.unauthorized);
    }
    return attempt;
  }

  Future<FirstPartyExternalStatus> status() => _run(() async {
        final b = _binding;
        if (b == null || _profile == null) {
          return FirstPartyExternalStatus(profileId: _selectedId);
        }
        try {
          final ref = await b.management.selectProfile(_selectedId!);
          final record = await b.management.read(ref);
          if (record.profile.revokedAtUtcMs != null ||
              record.grant == null ||
              record.grant!.revokedAtUtcMs != null ||
              (_session != null &&
                  record.grant!.revision != _sessionRevision)) {
            _forgetAccess();
            if (record.profile.revokedAtUtcMs != null ||
                b.credentials == null) {
              return FirstPartyExternalStatus(
                  profileId: _selectedId,
                  pairing: b.trust.snapshot(_profile!.principal).state);
            }
          }
          if (b.credentials != null) {
            final services = _credentials();
            var snapshot = b.trust.snapshot(_profile!.principal);
            FirstPartyPairingDisplay? display;
            if (_pairingRequest != null &&
                !_pairingFailed &&
                snapshot.state != PairingState.enabledForCurrentRuntime) {
              try {
                display = await _pairingRequest!.display();
              } catch (_) {
                _pairingFailed = true;
              }
            }
            // A request owns its own independently authenticated S. Do not
            // substitute the UI's auxiliary connection or disable that live
            // request because the auxiliary connection has already closed.
            final requestConnected =
                b.stageApproval?.hasLiveRequestFor(_selectedId) == true;
            final session =
                requestConnected ? null : await authenticatedSession();
            snapshot = b.trust.snapshot(_profile!.principal);
            return FirstPartyExternalStatus(
                profileId: _selectedId,
                pairing: snapshot.state,
                pairingAvailable: services.boundary.isCurrent,
                pairingDisplay: _pairingFailed ? null : display,
                pairingFailed: _pairingFailed,
                connected: requestConnected || session != null,
                enabled: requestConnected || session != null,
                expiresAt: snapshot.expiresAt,
                approvedTargets: _approvals.length);
          }
          _authenticate(b);
          final snapshot = b.trust.snapshot(_profile!.principal);
          if (_session?.failure != null) _forgetAccess();
          return FirstPartyExternalStatus(
              profileId: _selectedId,
              pairing: snapshot.state,
              connected: true,
              enabled: _session != null,
              expiresAt: snapshot.expiresAt,
              approvedTargets: _approvals.length);
        } catch (_) {
          _forgetAccess();
          return FirstPartyExternalStatus(profileId: _selectedId);
        }
      });

  Future<void> enable(Duration duration) => _run(() async {
        final b = _binding;
        if (b == null) externalAuthFail(ExternalAuthFailure.unauthorized);
        final services = b.credentials;
        if (services != null) _credentials();
        if (_pairingFailed) externalAuthFail(ExternalAuthFailure.unauthorized);
        final attempt = services == null ? _authenticate(b) : null;
        _forgetAccess();
        await b.coordinator.enable(_profile!, duration);
        try {
          final connection = services == null
              ? null
              : await services.openConnection(
                  await b.management.selectProfile(_selectedId!));
          final session = connection?.session ??
              await b.coordinator.openSession(_profile!, attempt!);
          if (!identical(session.principal, _profile!.principal) ||
              session.generation != b.trust.generation ||
              (connection != null &&
                  !identical(await connection.authenticate(), session))) {
            externalAuthFail(ExternalAuthFailure.unauthorized);
          }
          final access = await b.stages.runtimeAdmission.admit(session);
          if (access.grantSnapshot == null ||
              access.grantSnapshot!.revokedAtUtcMs != null) {
            externalAuthFail(ExternalAuthFailure.unauthorized);
          }
          if (services == null) _authenticate(b);
          if (connection != null &&
              !identical(await connection.authenticate(), session)) {
            externalAuthFail(ExternalAuthFailure.unauthorized);
          }
          _validate();
          if (session.failure != null) {
            externalAuthFail(ExternalAuthFailure.unauthorized);
          }
          _session = session;
          _connection = connection;
          _sessionRevision = access.grantSnapshot?.revision;
        } catch (_) {
          // Failed authentication/admission must never leave a hidden enablement.
          _forgetAccess();
          rethrow;
        }
      });

  Future<void> disable() => _run(() async {
        _forgetAccess();
        final b = _binding;
        if (b != null && _profile != null) {
          await b.coordinator.disable(_profile!);
        }
      });

  /// Trusted port rechecks the current Session and owning policy at every call.
  Future<ExternalSession?> authenticatedSession() async {
    try {
      _validate();
      final b = _binding!;
      if (b.credentials == null) {
        _authenticate(b);
      } else {
        _credentials();
        final connection = _connection;
        if (connection == null ||
            !identical(await connection.authenticate(), _session)) {
          _forgetAccess();
          return null;
        }
      }
      final session = _session;
      if (session == null || session.failure != null) return null;
      final access = await b.stages.runtimeAdmission.admit(session);
      if (access.grantSnapshot == null ||
          access.grantSnapshot!.revokedAtUtcMs != null ||
          access.grantSnapshot!.revision != _sessionRevision) {
        _forgetAccess();
        return null;
      }
      _validate();
      if (!identical(session, _session)) return null;
      if (b.credentials == null) {
        _authenticate(b);
      } else if (!identical(await _connection?.authenticate(), session)) {
        _forgetAccess();
        return null;
      }
      _validate();
      if (!identical(session, _session) || session.failure != null) return null;
      return session;
    } catch (_) {
      _forgetAccess();
      return null;
    }
  }

  Future<List<GeneratedReviewTargetChoice>> targets() => _run(() async {
        final session = await authenticatedSession();
        if (session == null) externalAuthFail(ExternalAuthFailure.unauthorized);
        final choices = await _binding!.localOwner.targets();
        _validate();
        _choices = List.unmodifiable(choices);
        return _choices;
      });

  FirstPartyStageApprovalView? openStageApprovalView() {
    _validate();
    final approval = _binding?.stageApproval;
    return approval?.host.isReady == true ? approval!.openView() : null;
  }

  /// Only the local confirmation of a displayed App choice invokes P3 approval.
  /// READ Contexts and client-supplied target names never enter this method.
  Future<void> approveTarget(GeneratedReviewTargetChoice choice) =>
      _run(() async {
        final session = await authenticatedSession();
        if (session == null || !_choices.any((c) => identical(c, choice))) {
          externalAuthFail(ExternalAuthFailure.unauthorized);
        }
        final approved = await _binding!.stages
            .approveTarget(session, choice.target, const []);
        _validate();
        if (!identical(session, _session) ||
            await authenticatedSession() == null) {
          externalAuthFail(ExternalAuthFailure.unauthorized);
        }
        _approvals.removeWhere((a) =>
            a.target.bankName == choice.target.bankName &&
            a.target.projectId == choice.target.projectId &&
            a.target.folderName == choice.target.folderName);
        if (_approvals.length >= 128) {
          externalAuthFail(ExternalAuthFailure.unauthorized);
        }
        _approvals.add(approved);
        _binding!.publishApprovals(List.unmodifiable(_approvals));
      });

  /// Blocks synchronously, then awaits local work and owning Host/port drain.
  Future<void> shutdown() {
    if (_shutdown != null) return _shutdown!;
    _closed = true;
    _forgetAccess();
    final owning = _binding?.shutdown() ?? Future<void>.value();
    return _shutdown =
        Future.wait([owning, _idle?.future ?? Future<void>.value()]);
  }
}
