import 'dart:async';
import 'dart:convert';
import '../../../mcp/vnext_mcp_server.dart';
import '../windows_local_relay.dart';
import 'link_initialization.dart';
import 'slot_ownership_store.dart';
import 'link_adapter_process.dart';
import 'link_installation.dart';
import 'link_state_store.dart';
import 'link_values.dart';
import 'link_verification_log.dart';
import 'link_call_diagnostics.dart';

typedef LinkBackendFactory = Future<LinkBackend> Function(
    {required bool proof,
    required String runId,
    required String resourceId,
    required Future<void> Function(LinkOwnerReference) acquired});

typedef LinkInitializationFactory = Future<LinkVerifiedTarget> Function({
  required String runId,
  required String resourceId,
  required void Function(String) onFingerprint,
});

/// Connection infrastructure only. No database, permission, or business writer.
final class LinkRuntime {
  LinkRuntime(
      {required this.installation,
      required this.store,
      LinkBackendFactory? backendFactory,
      LinkInitializationFactory? initializationFactory,
      this.verificationObserver,
      this.callDiagnostics})
      : _factory = backendFactory,
        _initializationFactory = initializationFactory,
        slots = SlotOwnershipStore(installation);
  final LinkInstallation installation;
  final LinkStateStore store;
  final SlotOwnershipStore slots;
  final LinkBackendFactory? _factory;
  final LinkInitializationFactory? _initializationFactory;
  final LinkVerificationObserver? verificationObserver;
  final LinkCallDiagnostics? callDiagnostics;
  String? _pairingFingerprint, _initializationFailure;
  Future<LinkBackend> _create(
          {required bool proof, required String resourceId}) =>
      _factory != null
          ? _factory(
              proof: proof,
              runId: runId,
              resourceId: resourceId,
              acquired: _captureOwner)
          : LinkAdapterProcess.start(installation,
              proof: proof,
              runId: runId,
              resourceId: resourceId,
              acquired: _captureOwner,
              verificationObserver: verificationObserver);
  final runId = linkNonce();
  LinkBackend? _backend;
  Future<void>? _operation, _call, _disconnecting, _closing;
  Future<void> _journal = Future<void>.value();
  bool _ready = false, _closed = false, _withdrawing = false;
  String? _peer, _connection;
  StreamController<void>? _cancel;
  bool _cancelRequested = false;
  int? _activeId;
  LinkState get state => store.state;
  bool mayDeliver(String peer, String connection) =>
      !_closed &&
      !_withdrawing &&
      _backend != null &&
      state.dirtyPhase == LinkDirtyPhase.active &&
      peer == _peer &&
      connection == _connection;

  Future<void> _record(Map<String, Object?> fields) {
    var publishing = false;
    final next = _journal.then((_) => slots.locked(() async {
          final previous = state;
          final next = previous.change(fields);
          final ownership = await slots.readLocked();
          if (ownership == null ||
              !ownership.owned ||
              ownership.value['ownerGeneration'] != previous.ownerGeneration) {
            linkFail();
          }
          var updated = ownership;
          if (next.owner != null) {
            updated = ownership.change({
              'resourceGeneration': next.owner!.resourceId,
              'lastSettlementState': 'DIRTY',
            });
          } else if (previous.owner != null &&
              next.dirtyPhase == LinkDirtyPhase.clean) {
            final original = previous.owner!;
            final receipt = await slots.receiptFor(original.resourceId);
            if (receipt['operationId'] != installation.operationId ||
                receipt['owner'] != installation.connectorInstanceId ||
                receipt['runId'] != original.runId ||
                receipt['processId'] != original.processId ||
                receipt['processStarted'] != original.processStarted ||
                jsonEncode(receipt['target']) !=
                    jsonEncode(ownership.target!.toJson())) {
              linkFail();
            }
            updated = ownership.change({
              'lastSettlementState': 'CLEAN',
              'lastSettlementRef': receipt['receiptRef'],
            });
          }
          // A rejected receipt has changed no state and may be followed by the
          // original owner's UNKNOWN diagnostic. Once publication begins,
          // retain a failed journal; never retry through uncertain persistence.
          publishing = true;
          if (!identical(updated, ownership)) {
            await slots.writeLocked(updated, ownership.revision);
          }
          await store.replace(next, expectedRevision: previous.revision);
        }));
    _journal = next.then((_) {}, onError: (Object error, StackTrace stack) {
      if (publishing) Error.throwWithStackTrace(error, stack);
    });
    unawaited(_journal.then((_) {}, onError: (Object _, StackTrace __) {}));
    unawaited(next.then((_) {}, onError: (Object _, StackTrace __) {}));
    return next;
  }

  Future<void> _exclusive(Future<void> Function() work) {
    if (_closed || _operation != null || _withdrawing) linkFail('busy');
    final done = Completer<void>();
    _operation = done.future;
    return () async {
      try {
        await work();
      } finally {
        _operation = null;
        done.complete();
      }
    }();
  }

  Map<String, Object?> inspect() => {
        'phase': state.dirtyPhase.name,
        'targetRef': state.targetRef,
        'selectionRevision': state.selectionRevision,
        'revision': state.revision,
        'prepared': _ready && !_closed && !_withdrawing,
        'ready': _backend != null &&
            state.dirtyPhase == LinkDirtyPhase.active &&
            !_closed &&
            !_withdrawing,
        'busy': _backend != null || _operation != null,
        'diagnostic': state.diagnostic,
        'initializationFailure': _initializationFailure,
        'pairingClientFingerprint': _pairingFingerprint,
        'delivery': state.delivery.name,
        'businessResult': state.businessResult.name,
        'settlement': state.settlement.name
      };

  Future<void> initialize() async {
    if (_operation != null || _closed) linkFail('busy');
    _pairingFingerprint = null;
    _initializationFailure = null;
    final visible = Completer<void>();
    final completed = _exclusive(() async {
      if (state.dirtyPhase == LinkDirtyPhase.clean) {
        await slots.requireOwned(state);
        return;
      }
      if (state.dirtyPhase != LinkDirtyPhase.initializing ||
          state.lease != null) {
        linkFail();
      }
      final initializer = LinkInitialization(installation);
      final original = await initializer.beginAttempt(store, runId);
      // The adapter journals its attempt before acquiring a key; the local
      // state stays PREPARING until verified credentials AND settlement exist.
      void displayFingerprint(String fingerprint) {
        linkToken(fingerprint, digest: true);
        _pairingFingerprint = fingerprint;
        if (!visible.isCompleted) visible.complete();
      }

      final backend = _initializationFactory == null
          ? await LinkAdapterProcess.initialize(installation,
              runId: original.runId,
              resourceId: original.resourceId,
              onFingerprint: displayFingerprint)
          : await _initializationFactory(
              runId: original.runId,
              resourceId: original.resourceId,
              onFingerprint: displayFingerprint);
      await initializer.complete(store, backend);
    });
    unawaited(completed.then((_) {
      _pairingFingerprint = null;
      if (!visible.isCompleted) visible.complete();
    }, onError: (Object error, StackTrace stack) {
      _pairingFingerprint = null;
      _initializationFailure = 'initialization_incomplete';
      if (!visible.isCompleted) visible.completeError(error, stack);
    }));
    // Local control returns the original comparison display while the one
    // owned operation continues. Inspect/close can observe/join that operation.
    await visible.future;
  }

  Future<void> select(String targetRef, int expectedSelectionRevision) =>
      _exclusive(() async {
        if (expectedSelectionRevision != state.selectionRevision) {
          linkFail('stale_revision');
        }
        if (targetRef != installation.slotRef) {
          linkFail('invalid_target');
        }
        // This exclusive operation already owns selection and cannot join itself.
        await _disconnect(waitForOperation: false);
        if (state.dirtyPhase != LinkDirtyPhase.clean) linkFail();
        await _record({
          'targetRef': targetRef,
          'selectionRevision': state.selectionRevision + 1,
          'routeGeneration': state.routeGeneration + 1
        });
      });

  Future<void> connect() => _exclusive(() async {
        if (_backend != null || _peer != null) linkFail('busy');
        if (state.dirtyPhase != LinkDirtyPhase.clean ||
            state.targetRef != installation.slotRef) {
          linkFail('unavailable');
        }
        await slots.requireOwned(state);
        final resource = linkNonce();
        await _markStarting(resource);
        try {
          await _create(proof: true, resourceId: resource);
          await _clean();
          if (!_closed && !_withdrawing) _ready = true;
        } catch (_) {
          await _unknown();
          rethrow;
        }
      });
  Future<void> _markStarting(String resource) => _record({
        'routeGeneration': state.routeGeneration + 1,
        'dirtyPhase': 'preparing',
        'owner': LinkOwnerReference(
                runId: runId,
                resourceId: resource,
                processId: 0,
                processStarted: 'not-created',
                slotRef: state.targetRef!)
            .toJson(),
        'settlement': 'unknown',
        'delivery': 'none',
        'businessResult': 'notStarted'
      });
  Future<void> _captureOwner(LinkOwnerReference owner) =>
      _record({'owner': owner.toJson()});
  Future<void> _clean() => _record({
        'owner': null,
        'lease': null,
        'dirtyPhase': 'clean',
        'settlement': 'clean',
        'diagnostic': 'none'
      });
  Future<void> _unknown() async {
    _ready = false;
    await _record({
      'dirtyPhase': 'recoveryRequired',
      'settlement': 'unknown',
      'diagnostic': 'owner_unsettled'
    });
  }

  Future<void> attach(String peer, String connection) => _exclusive(() async {
        if (_peer != null || _backend != null) linkFail('busy');
        if (!_ready || state.dirtyPhase != LinkDirtyPhase.clean) {
          linkFail('unavailable');
        }
        final target = await slots.requireOwned(state);
        if (_closed || _withdrawing) linkFail('unavailable');
        _peer = peer;
        _connection = connection;
        final resource = linkNonce();
        await _markStarting(resource);
        try {
          final backend =
              _backend = await _create(proof: false, resourceId: resource);
          unawaited(backend.disconnected.then((_) async {
            if (!identical(_backend, backend)) return;
            try {
              await disconnect();
            } catch (_) {/* Exact dirty owner remains. */}
          }));
          if (jsonEncode(backend.target.toJson()) !=
              jsonEncode(target.toJson())) {
            linkFail('device_mismatch');
          }
          // Late acquisition remains owned for disconnect, but cannot publish
          // a new business lease after withdrawal.
          if (_closed || _withdrawing) linkFail('unavailable');
          final lease = LinkLease(
              connectorRunId: runId,
              selectionRevision: state.selectionRevision,
              routeGeneration: state.routeGeneration,
              targetRef: state.targetRef!,
              target: backend.target,
              frontendPeerIdentity: peer,
              frontendConnectionId: connection,
              leaseId: linkNonce());
          await _record({'lease': lease.toJson(), 'dirtyPhase': 'active'});
          if (_closed || _withdrawing) linkFail('unavailable');
        } catch (_) {
          await _unknown();
          rethrow;
        }
      });

  Future<Map<String, Object?>> call(String peer, String connection, int id,
      String tool, Map<String, dynamic> arguments,
      {LinkCallTrace? diagnostic}) async {
    diagnostic?.bind(
        run: runId,
        connection: connection,
        call: id,
        originalLease: state.lease,
        originalOwner: state.owner);
    diagnostic?.stage(LinkCallStage.admission, LinkCallOutcome.entered);
    if (_closed ||
        _withdrawing ||
        _operation != null ||
        _backend == null ||
        state.dirtyPhase != LinkDirtyPhase.active ||
        peer != _peer ||
        connection != _connection) {
      diagnostic?.stage(LinkCallStage.admission, LinkCallOutcome.rejected,
          LinkCallCause.unavailable);
      linkFail('unavailable');
    }
    if (_call != null) {
      diagnostic?.stage(LinkCallStage.admission, LinkCallOutcome.rejected,
          LinkCallCause.busy);
      linkFail('busy');
    }
    if (!VnextMcpServer.schemasFor(3).containsKey(tool)) {
      diagnostic?.stage(LinkCallStage.admission, LinkCallOutcome.rejected,
          LinkCallCause.invalidRequest);
      linkFail('invalidRequest');
    }
    diagnostic?.stage(LinkCallStage.admission, LinkCallOutcome.succeeded);
    final done = Completer<void>();
    _call = done.future;
    _activeId = id;
    _cancelRequested = false;
    // Buffer an explicit cancellation that arrives during the journal write,
    // before the original backend has installed its cancellation listener.
    late StreamController<void> cancel;
    cancel = StreamController<void>.broadcast(
        sync: true,
        onListen: () {
          if (_cancelRequested) {
            scheduleMicrotask(() {
              if (!cancel.isClosed) cancel.add(null);
            });
          }
        });
    _cancel = cancel;
    try {
      await _record({'businessResult': 'pending', 'delivery': 'unknown'});
      diagnostic?.stage(LinkCallStage.backendCall, LinkCallOutcome.entered);
      final result = await _backend!.call(tool, arguments,
          cancelled: cancel.stream, diagnostic: diagnostic);
      diagnostic?.stage(LinkCallStage.backendCall, LinkCallOutcome.succeeded);
      await _record({
        'businessResult':
            result['error'] == 'outcome_unknown' ? 'unknown' : 'returned'
      });
      return result;
    } catch (error) {
      final prior = diagnostic?.stages[LinkCallStage.backendCall.index];
      if (error is TimeoutException ||
          prior == null ||
          prior[0] != LinkCallOutcome.failed.index ||
          prior[1] == LinkCallCause.none.index ||
          prior[1] == LinkCallCause.unknown.index) {
        diagnostic?.stage(
            LinkCallStage.backendCall,
            LinkCallOutcome.failed,
            error is TimeoutException
                ? LinkCallCause.timeout
                : LinkCallCause.unknown);
      }
      await _record({'businessResult': 'unknown'});
      return vnextFailure(
          tool == 'propose_generated_questions'
              ? 'outcome_unknown'
              : 'unavailable',
          profileVersion: 3);
    } finally {
      _activeId = null;
      _cancel = null;
      await cancel.close();
      _call = null;
      done.complete();
    }
  }

  void cancel(String peer, String connection, int id) {
    if (!_closed &&
        !_withdrawing &&
        peer == _peer &&
        connection == _connection &&
        id == _activeId &&
        !_cancelRequested) {
      _cancelRequested = true;
      _cancel?.add(null); // Only a real cancellation frame reaches this method.
    }
  }

  Future<void> delivered(bool delivered) =>
      _record({'delivery': delivered ? 'delivered' : 'unknown'});

  Future<void> disconnect() => _disconnect(waitForOperation: true);

  Future<void> _disconnect({required bool waitForOperation}) {
    if (_disconnecting != null) return _disconnecting!;
    _withdrawing = true;
    _ready = false;
    final operation = waitForOperation ? _operation : null;
    return _disconnecting = () async {
      try {
        // Keep withdrawal set until acquisition and lease publication finish.
        // A backend arriving during this join belongs to this same settlement.
        await operation;
        await _call; // EOF is not cancellation; retain the sole output consumer.
        final backend = _backend;
        if (backend != null) {
          final originalOwner = state.owner;
          final originalLease = state.lease;
          final originalRoute = state.routeGeneration;
          await _record({'dirtyPhase': 'draining', 'settlement': 'draining'});
          await backend.close();
          await _clean();
          _backend = null;
          if (originalOwner != null && originalLease != null) {
            observeLinkVerification(
                verificationObserver,
                () => LinkVerificationObservation.runtimeSettled(originalOwner,
                    lease: originalLease,
                    operationId: installation.operationId,
                    connectorInstanceId: installation.connectorInstanceId,
                    revision: state.revision,
                    routeGeneration: originalRoute));
          }
        }
        if (state.owner != null ||
            state.lease != null ||
            state.dirtyPhase == LinkDirtyPhase.recoveryRequired) {
          linkFail('owner_unsettled');
        }
        _peer = null;
        _connection = null;
      } catch (_) {
        await _unknown();
        rethrow;
      } finally {
        _withdrawing = false;
        _disconnecting = null;
      }
    }();
  }

  Future<void> close() {
    _closed = true;
    _ready = false;
    return _closing ??= () async {
      await disconnect();
      await _journal;
      await store.close();
    }();
  }
}

/// Separate authenticated pipes; no business method can select/recover a target.
final class LinkPipeServer {
  LinkPipeServer(this.runtime, this.business, this.control);
  final LinkRuntime runtime;
  final LocalRelayServerConnection business, control;
  bool _closed = false;
  bool _controlWithdrawing = false;
  final _controlClock = Stopwatch()..start();
  int _lastControl = -100;
  final _work = <Future<void>>{};
  Future<void> serve() async {
    await Future.wait([_serveBusiness(), _serveControl()]);
    await Future.wait(_work.toList());
  }

  Future<void> _serveBusiness() async {
    while (!_closed) {
      int? pendingDelivery;
      LinkCallTrace? receivingTrace, pendingTrace;
      Completer<void>? outputAcknowledged;
      try {
        await business.accept();
        final peer = business.linkPeerIdentity, connection = linkNonce();
        final envelope = {
          'version': 1,
          'runId': runtime.runId,
          'connectionId': connection
        };
        await business.send({
          ...envelope,
          'kind': 'hello',
          'capabilitySet': LinkLease.capabilitySet
        }, const Duration(seconds: 5));
        final hello = await business.receive(const Duration(seconds: 5));
        linkFields(hello,
            {'version', 'runId', 'connectionId', 'kind', 'capabilitySet'});
        if (hello['version'] != 1 ||
            hello['runId'] != runtime.runId ||
            hello['connectionId'] != connection ||
            hello['kind'] != 'attach' ||
            hello['capabilitySet'] != LinkLease.capabilitySet) {
          linkFail('invalidRequest');
        }
        if (_controlWithdrawing) linkFail('busy');
        await runtime.attach(peer, connection);
        await business.send({
          ...envelope,
          'kind': 'attached',
          'leaseId': runtime.state.lease!.leaseId
        }, const Duration(seconds: 5));
        var lastId = 0;
        while (!_closed && business.isCurrent) {
          final message = await business.receive(const Duration(hours: 8));
          final kind = message['kind'];
          if (kind == 'call') {
            receivingTrace =
                runtime.callDiagnostics?.begin(message['tool'], null);
            receivingTrace?.bind(
                run: runtime.runId,
                connection: connection,
                call: message['id'] is int && (message['id'] as int) > 0
                    ? message['id'] as int
                    : null,
                originalLease: runtime.state.lease,
                originalOwner: runtime.state.owner);
            receivingTrace?.stage(
                LinkCallStage.ipcReceive, LinkCallOutcome.entered);
          }
          linkFields(message, {
            'version',
            'runId',
            'connectionId',
            'kind',
            'id',
            if (kind == 'call') ...['tool', 'arguments']
          });
          final id = message['id'];
          if (message['version'] != 1 ||
              message['runId'] != runtime.runId ||
              message['connectionId'] != connection ||
              id is! int ||
              id < 1) {
            linkFail('invalidRequest');
          }
          if (kind == 'cancel') {
            runtime.cancel(peer, connection, id);
            continue;
          }
          if (kind == 'delivered') {
            if (pendingDelivery != id) linkFail('invalidRequest');
            await runtime.delivered(true);
            pendingTrace?.stage(
                LinkCallStage.deliveryAck, LinkCallOutcome.succeeded);
            pendingDelivery = null;
            outputAcknowledged?.complete();
            await Future.wait(_work.toList());
            runtime.callDiagnostics?.finish(pendingTrace);
            pendingTrace = null;
            continue;
          }
          if (kind != 'call' ||
              id != lastId + 1 ||
              message['tool'] is! String ||
              message['arguments'] is! Map<String, dynamic>) {
            linkFail('invalidRequest');
          }
          lastId = id;
          if (_work.isNotEmpty ||
              pendingDelivery != null ||
              _controlWithdrawing) {
            linkFail('busy');
          }
          pendingDelivery = id;
          pendingTrace = receivingTrace;
          receivingTrace = null;
          final diagnostic = pendingTrace;
          diagnostic?.stage(
              LinkCallStage.ipcReceive, LinkCallOutcome.succeeded);
          final acknowledged = outputAcknowledged = Completer<void>();
          late Future<void> task;
          task = () async {
            final result = await runtime.call(
                peer,
                connection,
                id,
                message['tool'] as String,
                message['arguments'] as Map<String, dynamic>,
                diagnostic: diagnostic);
            if (business.isCurrent && runtime.mayDeliver(peer, connection)) {
              diagnostic?.stage(
                  LinkCallStage.outputSend, LinkCallOutcome.entered);
              diagnostic?.stage(
                  LinkCallStage.deliveryAck, LinkCallOutcome.entered);
              try {
                await business.send(
                    {...envelope, 'kind': 'result', 'id': id, 'result': result},
                    const Duration(seconds: 5));
                diagnostic?.stage(
                    LinkCallStage.outputSend, LinkCallOutcome.succeeded);
              } catch (_) {
                diagnostic?.stage(LinkCallStage.outputSend,
                    LinkCallOutcome.failed, LinkCallCause.sendFailed);
                rethrow;
              }
              try {
                await acknowledged.future.timeout(const Duration(seconds: 5));
              } catch (_) {
                diagnostic?.stage(LinkCallStage.deliveryAck,
                    LinkCallOutcome.unknown, LinkCallCause.timeout);
                await runtime.delivered(false);
                await business.disconnect();
              }
            } else if (business.isCurrent) {
              await business.disconnect();
            }
          }()
              .whenComplete(() => _work.remove(task));
          _work.add(task);
          unawaited(task.then((_) {}, onError: (Object _, StackTrace __) {}));
        }
      } catch (error) {
        receivingTrace?.stage(
            LinkCallStage.ipcReceive,
            LinkCallOutcome.rejected,
            error is LinkException && error.code == 'busy'
                ? LinkCallCause.busy
                : error is LinkException && error.code == 'invalidRequest'
                    ? LinkCallCause.invalidFrame
                    : LinkCallCause.unknown);
        // No payload/unsafe exception is logged. Original work remains owned.
      } finally {
        final originalOwner = runtime.state.owner;
        final originalConnection = runtime.state.lease?.frontendConnectionId;
        final pendingWork = _work.length;
        var workFailed = false;
        if (outputAcknowledged?.isCompleted == false) {
          outputAcknowledged!.complete();
        }
        await Future.wait(_work
            .toList()
            .map((f) => f.then((_) {}, onError: (Object _, StackTrace __) {
                  workFailed = true;
                })));
        if (pendingDelivery != null) await runtime.delivered(false);
        if (pendingTrace != null) {
          if (pendingDelivery != null) {
            pendingTrace.stage(LinkCallStage.deliveryAck,
                LinkCallOutcome.unknown, LinkCallCause.eof);
          }
          runtime.callDiagnostics?.finish(pendingTrace);
        }
        runtime.callDiagnostics?.finish(receivingTrace);
        if (originalOwner != null) {
          observeLinkVerification(
              runtime.verificationObserver,
              () => LinkVerificationObservation.outputJoined(originalOwner,
                  frontendEnded: true,
                  frontendConnectionId: originalConnection,
                  delivery: runtime.state.delivery,
                  workFailed: workFailed,
                  pendingWork: pendingWork));
        }
        try {
          await runtime.disconnect();
        } catch (_) {/* Dirty blocks replacement. */}
        if (!_closed) await business.disconnect();
      }
    }
  }

  Future<void> _joinOutputWork() async {
    final originalOwner = runtime.state.owner;
    final originalConnection = runtime.state.lease?.frontendConnectionId;
    final pendingWork = _work.length;
    await Future.wait(_work.toList());
    if (originalOwner != null) {
      observeLinkVerification(
          runtime.verificationObserver,
          () => LinkVerificationObservation.outputJoined(originalOwner,
              frontendEnded: false,
              frontendConnectionId: originalConnection,
              delivery: runtime.state.delivery,
              workFailed: false,
              pendingWork: pendingWork));
    }
  }

  Future<void> _serveControl() async {
    while (!_closed) {
      final ticket = linkNonce();
      var replyStarted = false, shutdownFinished = false;
      try {
        await control.accept();
        await control.send(
            {'version': 1, 'ticket': ticket, 'runId': runtime.runId},
            const Duration(seconds: 5));
        final request = await control.receive(const Duration(seconds: 15));
        linkFields(request, {
          'version',
          'ticket',
          'runId',
          'action',
          'targetRef',
          'expectedSelectionRevision',
          'expectedRevision'
        });
        if (request['version'] != 1 ||
            request['ticket'] != ticket ||
            request['runId'] != runtime.runId) {
          linkFail('invalidRequest');
        }
        if (_controlClock.elapsedMilliseconds - _lastControl < 100) {
          linkFail('busy');
        }
        _lastControl = _controlClock.elapsedMilliseconds;
        switch (request['action']) {
          case 'inspect':
            break;
          case 'initialize':
            await runtime.initialize();
          case 'select':
            _controlWithdrawing = true;
            await _joinOutputWork();
            await runtime.select(linkToken(request['targetRef']),
                linkRevision(request['expectedSelectionRevision']));
          case 'connect':
            await runtime.connect();
          case 'disconnect':
            _controlWithdrawing = true;
            await _joinOutputWork();
            await runtime.disconnect();
          case 'shutdown':
            _controlWithdrawing = true;
            await _joinOutputWork();
            await runtime.close();
            shutdownFinished = true;
          default:
            linkFail('invalidRequest');
        }
        replyStarted = true;
        await _controlReply(
            ticket, {'version': 1, 'error': null, 'state': runtime.inspect()});
      } catch (error) {
        if (control.isCurrent && !replyStarted) {
          try {
            await _controlReply(ticket, {
              'version': 1,
              'error': error is LinkException ? error.code : 'unavailable',
              'state': runtime.inspect()
            });
          } catch (_) {/* Client gone. */}
        }
      } finally {
        _controlWithdrawing = false;
        // A lost management reply cannot undo completed original settlement.
        if (shutdownFinished) {
          _closed = true;
          await business.close();
        }
        if (!_closed) await control.disconnect();
      }
    }
    await control.close();
  }

  Future<void> _controlReply(String ticket, Map<String, Object?> result) async {
    await control.send(result, const Duration(seconds: 5));
    // DisconnectNamedPipe may discard bytes that the client has not read yet.
    // Retain the original pipe until this exact peer acknowledges its output.
    final receipt = await control.receive(const Duration(seconds: 5));
    linkFields(receipt, {'version', 'ticket', 'runId', 'kind'});
    if (receipt['version'] != 1 ||
        receipt['ticket'] != ticket ||
        receipt['runId'] != runtime.runId ||
        receipt['kind'] != 'received') {
      linkFail('invalidRequest');
    }
  }
}
