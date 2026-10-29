import 'dart:async';

import 'package:flutter/services.dart';

import '../application/capabilities/capability.dart';
import '../application/external/android_device_access.dart';
import '../application/external/android_foreground_access.dart';
import '../application/external/external_authorization.dart';
import '../application/external/external_credential_boundary.dart';
import '../application/external/external_trust_core.dart';
import '../application/external/first_party_external_credentials.dart';
import '../application/external/first_party_stage_approval.dart';
import '../application/external/local_authorization_service.dart';
import '../application/external/local_host_dispatch.dart';
import '../data/external/android_native_association_backend.dart';
import '../data/external/android_native_channel.dart';
import '../mcp/android_mcp_transport.dart' hide androidLinkFail;
import '../mcp/vnext_mcp_composition_root.dart';
import '../core/observability/app_logger.dart';
import 'android_device_foundation.dart';
import 'mcp_vnext_app_integration.dart';

/// App-owned Android composition. Construction opens no keys, policy or sockets.
final class AndroidDeviceApp implements AndroidDeviceAccess {
  AndroidDeviceApp(
      {required this.createIntegration,
      required this.policy,
      required this.applicationCurrent,
      required this.mintId}) {
    _foundation = AndroidDeviceFoundation(
        native: _native,
        elapsed: () => _clock.elapsed,
        nowUtcMs: () => _clock.now().millisecondsSinceEpoch);
    _events = _native.events.listen(_event);
  }
  final McpVnextAppIntegration Function() createIntegration;
  final LocalAuthorizationService policy;
  final bool Function() applicationCurrent;
  final String Function() mintId;
  final _native = AndroidDeviceMethodChannel();
  final _clock = _AndroidClock();
  final _changes = StreamController<void>.broadcast(sync: true);
  late AndroidDeviceFoundation _foundation;
  late StreamSubscription<(String, Map<String, Object?>)> _events;
  AndroidForegroundAccess get _foreground => _foundation.foreground;
  AndroidForegroundObservation? _observation;
  int? _nativeObservedMs, _nativePeriodEndsMs, _nativePreparationEndsMs;
  Duration _observationReceived = Duration.zero;
  Map<String, Object?>? _identity;
  McpVnextAppIntegration? _integration;
  AndroidChannelVerification? _verification;
  ExternalAuthorizationManagement? _management;
  ExternalCredentialBoundary? _boundary;
  VnextMcpAppComposition? _binding;
  ExternalProfileReference? _reference;
  _AndroidResources? _resources;
  String? _profile, _client, _address, _mode, _error;
  String _runtime = '';
  String? _businessId;
  bool _listening = false;
  void _stage(String stage) => AppLogger.info('Android access stage',
      module: 'MCP', data: {'stage': stage});
  bool _available = false, _paired = false, _disposed = false, _action = false;
  bool _recovery = false;
  DateTime? _expiresAt;
  Completer<void>? _confirmation, _proof;
  Future<void>? _stopping;
  Future<void>? _closing;
  ExternalAuthorizationRecord? _policyRecord;
  LocalAuthorizationView? _policyView;
  Future<void>? _policySaving;
  int _policyGeneration = 0;
  Timer? _deadline, _preparingDeadline;
  final _connections = <Future<void>>{};
  bool get _current => !_disposed && !_recovery && applicationCurrent();

  @override
  Stream<void> get changes => _changes.stream;
  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  @override
  AndroidDeviceAccessState get state => AndroidDeviceAccessState(
      available: _available,
      listening: _listening,
      connected: _businessId != null,
      phase: _recovery ? AndroidAccessPhase.recovery : _foreground.phase,
      address: _address,
      deviceId: _identity?['deviceId'] as String?,
      certificateDigest: _identity?['certificateDigest'] as String?,
      profileId: _profile,
      clientDigest: _client,
      paired: _paired,
      policyReady: _policyRecord?.grant != null &&
          _policyRecord?.profile.revokedAtUtcMs == null &&
          _policyRecord?.grant?.revokedAtUtcMs == null,
      policyChanging: _policySaving != null,
      fileContentAllowed: _policyRecord?.grant?.policy.categories
              .contains(ExternalContentCategory.fileContent) ??
          false,
      allContent: _policyRecord?.grant?.policy.allContent ?? false,
      hasFileScope: _policyRecord?.grant?.policy.scopes
              .any((scope) => scope.kind == ExternalTargetKind.file) ??
          false,
      generationMode: _generationMode,
      awaitingConfirmation: _confirmation != null,
      expiresAt: _expiresAt,
      error: _error);

  ExternalGenerationMode? get _generationMode {
    final grant = _policyRecord?.grant;
    if (grant == null ||
        grant.revokedAtUtcMs != null ||
        _policyRecord!.profile.revokedAtUtcMs != null ||
        !grant.policy.permissions.contains(CapabilityPermission.stage) ||
        !grant.policy.categories
            .contains(ExternalContentCategory.proposalMetadata)) {
      return null;
    }
    return grant.policy.generationMode;
  }

  @override
  Future<void> inspect() async {
    if (!_current || _policySaving != null) return;
    final policyGeneration = _policyGeneration;
    try {
      final status = await _native.invoke('status');
      if (status is! Map || status['runtimeAvailable'] != true) return;
      _available = true;
      if (status['observation'] is Map) {
        _observe(Map<String, Object?>.from(status['observation'] as Map));
      }
      if (_observation?.eligible == true) {
        await _loadIdentity(initialize: false);
      }
      final view = policy.openView();
      try {
        final profiles = (await view.profiles())
            .items
            .where((p) =>
                p.adapter == 'android-device' && p.revokedAtUtcMs == null)
            .toList();
        if (profiles.length > 1) androidLinkFail();
        if (profiles.length == 1) {
          final policyRecord = await view
              .read(await view.select(profiles.single.clientProfileId));
          if (!_current || policyGeneration != _policyGeneration) return;
          _policyRecord = policyRecord;
          _profile = profiles.single.clientProfileId;
          final snapshot = await _foundation.associations.read(_profile!);
          final record = snapshot.record;
          _paired = record != null &&
              !record.revoked &&
              record.installationId == _identity?['installationId'];
          _client = _paired ? record!.credentialIdentity : null;
        }
      } finally {
        view.close();
      }
    } on MissingPluginException {
      _available = false;
    } on PlatformException catch (error) {
      if (error.code != 'pairing_required') _error = '设备身份暂不可用';
    } catch (_) {
      _error = '设备状态需要检查';
    }
    _notify();
  }

  Future<void> _loadIdentity({required bool initialize}) async {
    Object? value;
    try {
      value = await _native.invoke('identity');
    } on PlatformException catch (e) {
      if (!initialize || e.code != 'pairing_required') rethrow;
      value = await _native.invoke('identity', {'initialize': true});
    }
    if (value is! Map ||
        value.length != 4 ||
        value['installationId'] is! String ||
        value['deviceId'] is! String ||
        value['certificateDigest'] is! String ||
        value['expiresAt'] is! int) {
      androidLinkFail();
    }
    _identity = Map<String, Object?>.from(value);
  }

  void _event((String, Map<String, Object?>) event) {
    final (name, value) = event;
    if (name == 'foreground') {
      _observe(value);
      return;
    }
    if (name == 'disconnected') {
      if (_businessId == value['channel']) _businessId = null;
      if (value['channel'] is String) {
        _verification?.invalidate(value['channel'] as String);
      }
      if (value['settled'] != true) {
        _recovery = true;
        _error = '原连接结算失败，请关闭访问';
      }
      _notify();
      return;
    }
    if (name != 'connected') return;
    final verification = _verification;
    if (verification == null) return;
    AndroidNativeChannel channel;
    try {
      channel = verification.accept(value);
    } catch (_) {
      late Future<void> retiring;
      retiring = _native.invoke(
          'channelClose', {'channel': value['channel']}).then<void>((result) {
        if (result != true) _recovery = true;
      }, onError: (Object _) {
        _recovery = true;
      }).whenComplete(() => _connections.remove(retiring));
      _connections.add(retiring);
      return;
    }
    late Future<void> work;
    work = _serve(channel, verification)
        .catchError((Object _) {})
        .whenComplete(() {
      _connections.remove(work);
      _notify();
    });
    _connections.add(work);
  }

  void _observe(Map<String, Object?> value) {
    if (value['sequence'] is! int) return;
    final next = AndroidForegroundObservation(
        sequence: value['sequence'] as int,
        resumed: value['resumed'] == true,
        focused: value['focused'] == true,
        interactive: value['interactive'] == true,
        unlocked: value['unlocked'] == true,
        visible: value['visible'] == true,
        network: value['network'] as String?);
    if (next.sequence <= (_observation?.sequence ?? -1)) return;
    final old = _observation;
    if (value['elapsedMs'] is int) {
      _nativeObservedMs = value['elapsedMs'] as int;
      _observationReceived = _clock.elapsed;
    }
    _observation = next;
    _address = value['address'] as String?;
    final wasPreparing = _foreground.phase == AndroidAccessPhase.preparing;
    if (!next.eligible || next.network != old?.network) {
      _verification?.invalidateAll();
    }
    _foreground.observe(next);
    if ((next.withdraws ||
            (old != null && next.network != old.network) ||
            wasPreparing && !next.eligible) &&
        _integration != null) {
      unawaited(disable());
    } else if (next.eligible &&
        _foreground.phase == AndroidAccessPhase.suspended &&
        _stopping == null) {
      unawaited(_foreground
          .resume((_) => _ListenerPreparation(this))
          .then((_) => _notify()));
    }
    _notify();
  }

  @override
  Future<void> observeFlutter(bool resumed) async {
    try {
      await _native.invoke('flutterLifecycle', {'resumed': resumed});
    } on MissingPluginException {
      /* Unadmitted platform keeps the entry absent. */
    }
  }

  @override
  Future<void> pair() => _begin('pairing');
  @override
  Future<void> enable() => _begin('enable-proof');
  Future<void> _begin(String mode) async {
    if (!_current ||
        !_available ||
        _action ||
        _policySaving != null ||
        _foreground.phase != AndroidAccessPhase.off ||
        _stopping != null ||
        _nativeObservedMs == null ||
        _observation?.eligible != true ||
        (mode == 'pairing' ? _paired : !_paired)) {
      androidLinkFail();
    }
    _action = true;
    _error = null;
    _mode = mode;
    final duration = mode == 'pairing'
        ? const Duration(seconds: 120)
        : const Duration(minutes: 30);
    _expiresAt = _clock.now().add(duration);
    // Native sampled before Dart received the event: this mapping is a
    // conservative ceiling. Preserve it unchanged across focus-only resumes.
    final nativeActionMs = _nativeObservedMs! +
        (_clock.elapsed - _observationReceived).inMilliseconds;
    _nativePeriodEndsMs = nativeActionMs + duration.inMilliseconds;
    _nativePreparationEndsMs = nativeActionMs + 120000;
    _preparingDeadline = Timer(const Duration(seconds: 120), () {
      unawaited(disable());
    });
    _deadline = Timer(duration, () {
      unawaited(disable());
    });
    try {
      await _foreground.enable((_) => _AccessPreparation(this, mode),
          duration: duration);
      if (_foreground.phase != AndroidAccessPhase.ready || !_current) {
        androidLinkFail();
      }
      _preparingDeadline?.cancel();
      if (mode == 'pairing') {
        _paired = true;
        await disable();
      }
    } catch (_) {
      _error = '连接未完成；请确认手机保持前台，再运行桌面连接助手。';
      await disable();
    } finally {
      _action = false;
      _notify();
    }
  }

  Future<void> _prepare(String mode, _AccessPreparation operation) async {
    _stage('identity');
    await _loadIdentity(initialize: mode == 'pairing');
    operation.check();
    final identity = _identity!;
    final integration = _integration = createIntegration();
    final verifier = _verification = AndroidChannelVerification(_native,
        elapsed: () => _clock.elapsed,
        current: () => _current && identical(_integration, integration),
        installationId: identity['installationId']! as String,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(
            identity['expiresAt']! as int,
            isUtc: true));
    _runtime = mintId();
    _stage('application-attach');
    await integration.attachCredentials(
        associations: _foundation.associations,
        verification: (management) {
          _management = management;
          return verifier;
        },
        clock: _clock,
        installationId: identity['installationId']! as String,
        readiness: _AndroidReadiness(() => _current && applicationCurrent()),
        monotonicNow: () => _clock.elapsed,
        enableStageApprovalWait: true,
        maxEnableDuration: const Duration(hours: 8),
        enableWithoutRetainedChannel: true,
        services: (boundary) {
          _boundary = boundary;
          return FirstPartyCredentialServices(
              boundary: boundary,
              pairing: _NoPairingPort(),
              openConnection: (_) async =>
                  throw StateError('android_separate_business_required'),
              close: verifier.close);
        },
        transport: (_, binding) {
          _binding = binding;
          return _AndroidBinding(binding);
        });
    operation.check();
    final management = _management!;
    _stage('local-profile');
    var profile = _profile;
    if (mode == 'pairing' && profile == null) {
      final created = await management.createProfile(
          displayName: 'Codex Android',
          adapter: 'android-device',
          protocol: 'android-device-link');
      profile = _profile = created.profileId;
    }
    if (profile == null) androidLinkFail();
    final reference = _reference = await management.selectProfile(profile);
    operation.check();
    await integration.controls.select(profile);
    _stage('association');
    final snapshot = await _foundation.associations.read(profile);
    operation.check();
    if (mode == 'enable-proof') {
      final record = snapshot.record;
      if (record == null ||
          record.revoked ||
          record.installationId != identity['installationId']) {
        androidLinkFail();
      }
      _client = record.credentialIdentity;
      // First access saves this delivery's READ grant. Later enables preserve
      // the original saved policy; current P4 checks still decide every call.
      var policyRecord = await management.read(reference);
      if (policyRecord.grant == null) {
        policyRecord = await management.replaceGrant(reference,
            policyRecord.profile.grantRevision, androidQuestionReadPolicy());
      } else if (policyRecord.grant!.revokedAtUtcMs != null ||
          !policyRecord.grant!.policy.permissions
              .contains(CapabilityPermission.read)) {
        androidLinkFail();
      }
      _policyRecord = policyRecord;
    }
    operation.check();
    final proof = _proof = Completer<void>();
    unawaited(proof.future.catchError((Object _) {}));
    _stage('listener-open');
    await _openListener();
    operation.check();
    _notify();
    await proof.future;
    _stage('proof-settled');
    operation.check();
    if (mode == 'enable-proof') {
      // Both proof endpoints have closed before the original finite P0 enable.
      await integration.controls.enable(_foreground.remaining);
      operation.check();
      if (await _native.invoke('linkEnabled', {'link': _resources!.link}) !=
          true) {
        androidLinkFail();
      }
      operation.check();
      _mode = 'business';
    }
  }

  Future<_AndroidResources> _openListener() async {
    final resource = _resources = _AndroidResources(this);
    try {
      await resource.opened;
      _listening = true;
      _stage('listening');
      if (!_current || _observation?.eligible != true) androidLinkFail();
      return resource;
    } catch (_) {
      await resource.close();
      rethrow;
    }
  }

  Future<void> _serve(
      AndroidNativeChannel channel, AndroidChannelVerification verifier) async {
    ExternalExistingCredentialConfirmation? existing;
    var proofCompleted = false;
    var proofOwned = false;
    Future<(int, Map<String, dynamic>)>? closingRead;
    Completer<void>? decision;
    var proofSent = false;
    void peerLeftOrReordered() {
      channel.invalidate();
      if (decision != null && !decision.isCompleted) {
        decision.completeError(StateError('android_peer_left'));
      }
      unawaited(channel.close().catchError((Object _) {
        _recovery = true;
      }));
    }

    var stage = 'hello';
    try {
      final (kind, hello) = await channel.read();
      stage = 'hello-fields';
      androidFields(hello, {
        'type',
        'purpose',
        'expectedDeviceId',
        'expectedProfileId',
        'clientNonce',
        'linkVersions'
      });
      final purpose = hello['purpose'];
      AppLogger.info('Android HELLO checks', module: 'MCP', data: {
        'control': kind == 1,
        'type': hello['type'] == 'hello',
        'device': hello['expectedDeviceId'] == _identity?['deviceId'],
        'purpose': purpose == _mode,
        'profile': hello['expectedProfileId'] ==
            (purpose == 'pairing' ? null : _profile),
        'preparing': _foreground.phase == AndroidAccessPhase.preparing,
      });
      stage = 'hello-values';
      if (kind != 1 ||
          hello['type'] != 'hello' ||
          hello['expectedDeviceId'] != _identity?['deviceId'] ||
          !androidNonceIsValid(hello['clientNonce']) ||
          hello['linkVersions'] is! List ||
          (hello['linkVersions'] as List).length != 1 ||
          (hello['linkVersions'] as List).single is! int ||
          (hello['linkVersions'] as List).single != 1 ||
          purpose != _mode ||
          hello['expectedProfileId'] !=
              (purpose == 'pairing' ? null : _profile)) {
        androidLinkFail();
      }
      if (purpose == 'business'
          ? !_foreground.acceptsNew
          : _foreground.phase != AndroidAccessPhase.preparing) {
        androidLinkFail();
      }
      proofOwned = purpose != 'business';
      stage = 'hello-association';
      final reference = _reference!,
          boundary = _boundary!,
          management = _management!;
      final snapshot = await _foundation.associations.read(reference.profileId);
      final record = snapshot.record;
      if (purpose != 'pairing' &&
          (record == null ||
              record.revoked ||
              record.credentialIdentity != channel.peer ||
              record.installationId != channel.installationId)) {
        androidLinkFail();
      }
      final clientNonce = hello['clientNonce'] as String,
          serverNonce = androidNonce();
      final binding = {
        'connectionId': channel.id,
        'clientNonce': clientNonce,
        'serverNonce': serverNonce
      };
      if (purpose == 'business') {
        stage = 'business-authentication';
        final policyRecord = await management.read(reference);
        final businessCurrent = await _integration!.controls
            .admitBusinessConnection(
                reference, policyRecord.profile.grantRevision);
        final event = await verifier.event(channel, reference,
            purpose: 'business',
            revision: record!.revision,
            association: snapshot);
        final session = await boundary.openSession(reference, event);
        verifier.bindSession(event, session);
        bool current() {
          try {
            businessCurrent();
            return _foreground.acceptsNew && verifier.isLive(event);
          } catch (_) {
            return false;
          }
        }

        final appBinding = _binding!;
        final port = AndroidMcpPort(
            VnextMcpAppComposition(
                host: appBinding.host,
                reads: appBinding.reads,
                stages: appBinding.stages,
                stageApproval: appBinding.stageApproval,
                approvedTargets: const [],
                authentication: VnextMcpSessionAuthentication(() async =>
                    current() && await channel.attest() ? session : null)),
            current);
        final transport = AndroidMcpTransport(
            port: port,
            newNonce: androidNonce,
            validNonce: androidNonceIsValid,
            read: channel.read,
            write: channel.write,
            closeChannel: channel.close,
            invalidate: channel.invalidate,
            connectionId: channel.id,
            current: current);
        final server = androidDeviceServer(port);
        await channel.write(1, {
          'type': 'ready',
          'linkVersion': 1,
          'deviceId': _identity!['deviceId'],
          'profileId': reference.profileId,
          'runtimeId': _runtime,
          ...binding
        });
        await channel.established();
        _businessId = channel.id;
        _notify();
        try {
          await server.serveTransport(transport);
        } catch (_) {
          // The server joins its original port and transport close. Failed
          // business settlement must not become a replaceable native channel.
          _recovery = true;
          _verification?.invalidateAll();
          rethrow;
        }
        return;
      }
      stage = 'offer';
      await channel.write(1, {
        'type': 'offer',
        'purpose': purpose,
        'deviceId': _identity!['deviceId'],
        'installationId': channel.installationId,
        'profileId': reference.profileId,
        'runtimeId': _runtime,
        ...binding,
        'clientCertificateDigest': channel.peer,
        'serverCertificateDigest': _identity!['certificateDigest'],
        'associationRevision': record?.revision ?? 0
      });
      await channel.established();
      if (purpose == 'pairing') decision = _confirmation = Completer<void>();
      final originalRead = closingRead = channel.read();
      unawaited(originalRead.then<void>((_) {
        if (!proofSent) peerLeftOrReordered();
      }, onError: (Object _, StackTrace __) {
        peerLeftOrReordered();
      }));
      stage = 'p15';
      var revision = record?.revision ?? 0;
      if (purpose == 'pairing') {
        _client = channel.peer;
        _notify();
        await decision!.future;
        _confirmation = null;
        if (_foreground.phase != AndroidAccessPhase.preparing ||
            !await channel.attest()) {
          androidLinkFail();
        }
        await channel.proofStarted();
        final registration = await boundary.requestPairing(reference,
            requestId: mintId(),
            credentialIdentity: channel.peer,
            expectedRevision: revision);
        await boundary.approvePairing(registration);
        final event = await verifier.event(channel, reference,
            purpose: 'pairing', revision: revision);
        await boundary.completePairing(registration, event);
        revision = (await boundary.confirmedPairing(registration)).revision;
      } else {
        await channel.proofStarted();
        final event = await verifier.event(channel, reference,
            purpose: 'enable-proof', revision: revision, association: snapshot);
        existing = await boundary.prepareExistingConfirmation(reference, event);
        await boundary.confirmExistingCredential(existing);
      }
      stage = 'proof-complete';
      final settlementNonce = androidNonce();
      proofSent = true;
      await channel.write(1, {
        'type': 'proof-complete',
        ...binding,
        'profileId': reference.profileId,
        'associationRevision': revision,
        'settlementNonce': settlementNonce,
      });
      final (closeKind, closing) = await originalRead;
      androidFields(closing, {
        'type',
        'connectionId',
        'clientNonce',
        'serverNonce',
        'settlementNonce'
      });
      if (closeKind != 1 ||
          closing['type'] != 'closing' ||
          closing['settlementNonce'] != settlementNonce ||
          binding.entries.any((e) => closing[e.key] != e.value)) {
        androidLinkFail();
      }
      await channel.peerClosed();
      proofCompleted = true;
    } catch (error) {
      _stage('connection-failed-$stage');
      AppLogger.info('Android channel refusal', module: 'MCP', data: {
        'category': error is PlatformException
            ? 'native-${error.code}'
            : error is StateError
                ? 'state'
                : error is FormatException
                    ? 'json'
                    : error is TypeError
                        ? 'type'
                        : error is UnsupportedError
                            ? 'buffer-ownership'
                            : 'adapter',
      });
      rethrow;
    } finally {
      try {
        await verifier.retire(channel);
        if (closingRead != null) {
          try {
            await closingRead;
          } catch (_) {/* Original retirement above owns cleanup. */}
        }
        if (existing != null) _boundary?.releaseExistingConfirmation(existing);
        if (proofCompleted && _proof?.isCompleted == false) _proof!.complete();
      } catch (_) {
        _recovery = true;
        proofCompleted = false;
        rethrow;
      } finally {
        if (proofOwned && !proofCompleted && _proof?.isCompleted == false) {
          _proof!.completeError(StateError('android_proof_failed'));
        }
      }
    }
  }

  @override
  void confirmPairing() {
    final decision = _confirmation;
    if (_foreground.phase != AndroidAccessPhase.preparing ||
        _mode != 'pairing' ||
        decision == null ||
        decision.isCompleted ||
        _observation?.eligible != true) {
      androidLinkFail();
    }
    decision.complete();
    _notify();
  }

  void _cancelPreparation() {
    _verification?.invalidateAll();
    if (_confirmation?.isCompleted == false) {
      _confirmation!.completeError(StateError('cancelled'));
    }
    if (_proof?.isCompleted == false) {
      _proof!.completeError(StateError('cancelled'));
    }
    _confirmation = null;
    _resources?.withdraw();
  }

  @override
  FirstPartyStageApprovalView? openStageApprovalView() =>
      _integration?.controls.openStageApprovalView();

  /// The explicit phone action preserves scope through the original local
  /// policy owner. Saving never enables access; the next Enable uses fresh proof.
  @override
  Future<void> setGenerationMode(ExternalGenerationMode? mode) =>
      _savePolicy((view, reference, revision) =>
          view.saveQuestionGeneration(reference, revision, mode: mode));

  @override
  Future<void> setFileContentAllowed(bool allowed) =>
      _savePolicy((view, reference, revision) =>
          view.saveFileContent(reference, revision, allowed: allowed));

  Future<void> _savePolicy(
      Future<ExternalAuthorizationRecord> Function(
              LocalAuthorizationView, ExternalProfileReference, int)
          save) {
    final profile = _profile;
    final record = _policyRecord;
    if (!_current ||
        !_paired ||
        !_available ||
        _action ||
        _policySaving != null ||
        profile == null ||
        record?.grant == null ||
        record!.profile.clientProfileId != profile) {
      androidLinkFail();
    }
    final generation = ++_policyGeneration;
    final view = _policyView = policy.openView();
    // Withdrawal occurs synchronously, before the first policy read or CAS.
    final withdrawal = _disableRuntime();
    bool current() =>
        _current &&
        view.isCurrent &&
        generation == _policyGeneration &&
        _profile == profile;
    final work = _policySaving = () async {
      try {
        await withdrawal;
        if (!current()) androidLinkFail();
        final reference = await view.select(profile);
        if (!current()) androidLinkFail();
        final saved = await save(view, reference, record.profile.grantRevision);
        if (!current()) androidLinkFail();
        _policyRecord = saved;
        _error = null;
      } catch (_) {
        _policyRecord = null;
        _error = '设置未确认；访问保持关闭，请重新核对授权。';
        rethrow;
      } finally {
        view.close();
        if (identical(_policyView, view)) _policyView = null;
        _policySaving = null;
        _notify();
      }
    }();
    _notify();
    return work;
  }

  void _cancelPolicy() {
    _policyGeneration++;
    _policyView?.close();
  }

  @override
  Future<void> cancelPending() async {
    _cancelPolicy();
    final saving = _policySaving;
    if (_foreground.phase == AndroidAccessPhase.preparing) {
      await disable();
    }
    try {
      await saving;
    } catch (_) {/* Failed local save never restores access. */}
  }

  @override
  Future<void> disable() {
    _cancelPolicy();
    final saving = _policySaving;
    final closing = _disableRuntime();
    return Future.wait([
      closing,
      if (saving != null) saving.catchError((Object _) {}),
    ]).then((_) {});
  }

  Future<void> _disableRuntime() {
    if (_stopping != null) return _stopping!;
    _deadline?.cancel();
    _preparingDeadline?.cancel();
    _expiresAt = null;
    _cancelPreparation();
    return _stopping = () async {
      try {
        // Cancel before join; P0 is withdrawn even while transport drain is pending.
        await _integration?.controls.disable();
        await _foreground.disable();
        await _resources?.close();
        await _integration?.close();
        _integration = null;
        _verification = null;
        _management = null;
        _boundary = null;
        _binding = null;
        _reference = null;
        _mode = null;
        _resources = null;
        if (_foreground.phase == AndroidAccessPhase.recovery) _recovery = true;
      } catch (_) {
        _recovery = true;
        _error = '原资源未完成结算；访问保持关闭';
      } finally {
        _stopping = null;
        _notify();
      }
    }();
  }

  @override
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _disposed = true;
    await disable();
    await _events.cancel();
    await _foundation.close();
    await _native.close();
    await _changes.close();
    if (_recovery) androidLinkFail();
  }
}

final class _AccessPreparation implements AndroidAccessPreparation {
  _AccessPreparation(this.owner, this.mode) {
    result = () async {
      await owner._prepare(mode, this);
      check();
      return owner._resources!;
    }();
    settled = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
  }
  final AndroidDeviceApp owner;
  final String mode;
  bool cancelled = false;
  @override
  late final Future<AndroidAccessResources> result;
  @override
  late final Future<void> settled;
  void check() {
    if (cancelled || !owner._current || owner._observation?.eligible != true) {
      androidLinkFail();
    }
  }

  @override
  void cancel() {
    cancelled = true;
    owner._cancelPreparation();
  }
}

final class _ListenerPreparation implements AndroidAccessPreparation {
  _ListenerPreparation(this.owner) {
    result = owner._openListener();
    settled = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
  }
  final AndroidDeviceApp owner;
  @override
  late final Future<AndroidAccessResources> result;
  @override
  late final Future<void> settled;
  @override
  void cancel() {
    owner._resources?.withdraw();
  }
}

final class _AndroidResources implements AndroidAccessResources {
  _AndroidResources(this.owner) {
    opened = () async {
      final reply = await owner._native.invoke('linkOpen', {
        'address': owner._address,
        'enrollment': owner._mode == 'pairing',
        'peer': owner._mode == 'pairing' ? null : owner._client,
        'periodEndsMs': owner._nativePeriodEndsMs,
        'preparationEndsMs': owner._nativePreparationEndsMs,
        'businessResume': owner._mode == 'business',
      });
      if (reply is! Map ||
          reply.length != 2 ||
          reply['port'] != 46443 ||
          reply['link'] is! String) {
        androidLinkFail();
      }
      link = reply['link'] as String;
    }();
  }
  final AndroidDeviceApp owner;
  late final Future<void> opened;
  String? link;
  Future<void>? _closing;
  @override
  void withdraw() {
    owner._listening = false;
    owner._businessId = null;
    owner._verification?.invalidateAll();
    unawaited(close().catchError((Object _) {}));
  }

  @override
  Future<void> close() => _closing ??= () async {
        owner._verification?.invalidateAll();
        try {
          await opened;
        } on PlatformException catch (e) {
          if (e.code == 'settlement_unknown') rethrow;
          return;
        }
        // Native close unblocks every original read/write before their Dart joins.
        if (await owner._native.invoke('linkClose', {'link': link}) != true) {
          androidLinkFail();
        }
        // Native has stopped accepting and posted all original channel events.
        // Include late arrivals/rejected peers in this SAME owner's drain.
        while (owner._connections.isNotEmpty) {
          await Future.wait(owner._connections.toList());
        }
        if (await owner._native.invoke('linkRelease', {'link': link}) != true) {
          androidLinkFail();
        }
      }();
}

final class _AndroidClock implements ExternalClock {
  final _start = DateTime.now().toUtc();
  final _timer = Stopwatch()..start();
  Duration get elapsed => _timer.elapsed;
  @override
  DateTime now() => _start.add(elapsed);
}

final class _AndroidReadiness implements LocalHostReadinessPort {
  _AndroidReadiness(this.current);
  final bool Function() current;
  void _check() {
    if (!current()) androidLinkFail();
  }

  @override
  bool get isCurrent => current();
  @override
  Future<void> ensureDatabaseReady() async => _check();
  @override
  Future<void> ensureRecoveryComplete() async => _check();
  @override
  Future<void> ensureModulesAndRoutesReady() async => _check();
}

final class _AndroidBinding implements McpVnextAppTransport {
  _AndroidBinding(this.binding);
  @override
  final VnextMcpAppComposition binding;
  @override
  Future<void> start() async {}
  @override
  Future<void> close() async {}
}

final class _NoPairingPort implements FirstPartyPairingPort {
  @override
  Future<FirstPartyPairingRequest> request(
          ExternalProfileReference profile) async =>
      throw StateError('android_native_pairing_required');
  @override
  Future<void> close() async {}
}
