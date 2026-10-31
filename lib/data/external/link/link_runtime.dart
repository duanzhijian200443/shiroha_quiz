import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../../../mcp/vnext_mcp_server.dart';
import '../windows_local_relay.dart';
import 'host_handoff.dart';
import 'link_adapter_process.dart';
import 'link_installation.dart';
import 'link_state_store.dart';
import 'link_values.dart';

typedef LinkBackendFactory = Future<LinkBackend> Function(
    {required bool proof,
    required String runId,
    required String resourceId,
    required Future<void> Function(LinkOwnerReference) acquired});

/// Connection infrastructure only. No database, permission, or business writer.
final class LinkRuntime {
  LinkRuntime(
      {required this.installation,
      required this.store,
      LinkBackendFactory? backendFactory})
      : _factory = backendFactory,
        handoff = HostHandoffStore(Directory(installation.slotDirectory));
  final LinkInstallation installation;
  final LinkStateStore store;
  final HostHandoffStore handoff;
  final LinkBackendFactory? _factory;
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
              windows: state.targetRef == 'windows',
              acquired: _captureOwner);
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
    final next = _journal.then((_) =>
        store.replace(state.change(fields), expectedRevision: state.revision));
    _journal = next;
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
        'delivery': state.delivery.name,
        'businessResult': state.businessResult.name,
        'settlement': state.settlement.name
      };

  Future<void> claim() => _exclusive(() async {
        if (_backend != null) linkFail('busy');
        await handoff.claim(store, slotRef: installation.slotRef);
      });
  Future<void> recover(int expectedRevision) => _exclusive(() async {
        final snapshot = state;
        if (snapshot.revision != expectedRevision ||
            _backend != null ||
            _peer != null ||
            snapshot.owner == null ||
            !{
              LinkDirtyPhase.preparing,
              LinkDirtyPhase.active,
              LinkDirtyPhase.draining,
              LinkDirtyPhase.recoveryRequired
            }.contains(snapshot.dirtyPhase)) {
          linkFail('recovery_required');
        }
        final claim =
            await handoff.requireClaim(snapshot, installation.slotRef);
        final receipt = await handoff.settledReceipt();
        linkFields(receipt, {
          'formatVersion',
          'runId',
          'resourceId',
          'processId',
          'processStarted',
          'slotRef',
          'owner',
          'mode',
          'target',
          'targetClose',
          'tlsShutdown',
          'keyRetired'
        });
        final original = snapshot.owner!;
        if (receipt['formatVersion'] != 1 ||
            receipt['runId'] != original.runId ||
            receipt['resourceId'] != original.resourceId ||
            receipt['slotRef'] != installation.slotRef ||
            receipt['owner'] != snapshot.connectorInstanceId ||
            !{'enable-proof', 'business'}.contains(receipt['mode']) ||
            receipt['targetClose'] != true ||
            receipt['tlsShutdown'] != true ||
            receipt['keyRetired'] != true ||
            jsonEncode(receipt['target']) !=
                jsonEncode(claim.target.toJson()) ||
            original.processId != 0 &&
                receipt['processId'] != original.processId ||
            !{'not-created', 'awaiting-adapter'}
                    .contains(original.processStarted) &&
                receipt['processStarted'] != original.processStarted ||
            WindowsLocalRelay.linkProcessCurrent(
                linkRevision(receipt['processId']),
                linkToken(receipt['processStarted']))) {
          linkFail('recovery_required');
        }
        await _record({
          'owner': null,
          'lease': null,
          'dirtyPhase': 'clean',
          'settlement': 'clean',
          'diagnostic': 'none',
          'routeGeneration': snapshot.routeGeneration + 1
        });
      });

  Future<void> select(String targetRef, int expectedSelectionRevision) =>
      _exclusive(() async {
        if (expectedSelectionRevision != state.selectionRevision) {
          linkFail('stale_revision');
        }
        if (targetRef != installation.slotRef &&
            !(targetRef == 'windows' &&
                installation.windowsClientExecutable != null)) {
          linkFail('invalid_target');
        }
        await disconnect();
        if (state.dirtyPhase != LinkDirtyPhase.clean) linkFail();
        await _record({
          'targetRef': targetRef,
          'selectionRevision': state.selectionRevision + 1,
          'routeGeneration': state.routeGeneration + 1
        });
      });

  Future<void> connect() => _exclusive(() async {
        if (_backend != null || _peer != null) linkFail('busy');
        if (state.targetRef == 'windows' &&
            state.dirtyPhase == LinkDirtyPhase.clean &&
            installation.windowsClientExecutable != null) {
          _ready = true;
          return;
        }
        if (state.dirtyPhase != LinkDirtyPhase.clean ||
            state.targetRef != installation.slotRef) {
          linkFail('unavailable');
        }
        await handoff.requireClaim(state, installation.slotRef);
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
        final claim = state.targetRef == 'windows'
            ? null
            : await handoff.requireClaim(state, installation.slotRef);
        _peer = peer;
        _connection = connection;
        final resource = linkNonce();
        await _markStarting(resource);
        try {
          final backend =
              _backend = await _create(proof: false, resourceId: resource);
          unawaited(backend.disconnected.then((_) async {
            if (!identical(_backend, backend)) return;
            _ready = false;
            _withdrawing = true;
            try {
              // Lease publication may still be in flight. Withdraw immediately,
              // then join that publication before settling its exact owner.
              await _operation;
              await disconnect();
            } catch (_) {/* Exact dirty owner remains. */}
          }));
          if (claim != null &&
              jsonEncode(backend.target.toJson()) !=
                  jsonEncode(claim.target.toJson())) {
            linkFail('device_mismatch');
          }
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
      String tool, Map<String, dynamic> arguments) async {
    if (_closed ||
        _withdrawing ||
        _operation != null ||
        _backend == null ||
        state.dirtyPhase != LinkDirtyPhase.active ||
        peer != _peer ||
        connection != _connection) {
      linkFail('unavailable');
    }
    if (_call != null) linkFail('busy');
    if (!VnextMcpServer.schemasFor(3).containsKey(tool)) {
      linkFail('invalidRequest');
    }
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
      final result =
          await _backend!.call(tool, arguments, cancelled: cancel.stream);
      await _record({
        'businessResult':
            result['error'] == 'outcome_unknown' ? 'unknown' : 'returned'
      });
      return result;
    } catch (_) {
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

  Future<void> disconnect() {
    if (_disconnecting != null) return _disconnecting!;
    _withdrawing = true;
    _ready = false;
    return _disconnecting = () async {
      try {
        await _call; // EOF is not cancellation; retain the sole output consumer.
        final backend = _backend;
        if (backend != null) {
          await _record({'dirtyPhase': 'draining', 'settlement': 'draining'});
          await backend.close();
          await _clean();
          _backend = null;
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
      await _operation;
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
            pendingDelivery = null;
            outputAcknowledged?.complete();
            await Future.wait(_work.toList());
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
          final acknowledged = outputAcknowledged = Completer<void>();
          late Future<void> task;
          task = () async {
            final result = await runtime.call(
                peer,
                connection,
                id,
                message['tool'] as String,
                message['arguments'] as Map<String, dynamic>);
            if (business.isCurrent && runtime.mayDeliver(peer, connection)) {
              await business.send(
                  {...envelope, 'kind': 'result', 'id': id, 'result': result},
                  const Duration(seconds: 5));
              try {
                await acknowledged.future.timeout(const Duration(seconds: 5));
              } catch (_) {
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
      } catch (_) {
        // No payload/unsafe exception is logged. Original work remains owned.
      } finally {
        if (outputAcknowledged?.isCompleted == false) {
          outputAcknowledged!.complete();
        }
        await Future.wait(_work
            .toList()
            .map((f) => f.then((_) {}, onError: (Object _, StackTrace __) {})));
        if (pendingDelivery != null) await runtime.delivered(false);
        try {
          await runtime.disconnect();
        } catch (_) {/* Dirty blocks replacement. */}
        if (!_closed) await business.disconnect();
      }
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
          case 'claim':
            await runtime.claim();
          case 'recover':
            await runtime.recover(linkRevision(request['expectedRevision']));
          case 'select':
            _controlWithdrawing = true;
            await Future.wait(_work.toList());
            await runtime.select(linkToken(request['targetRef']),
                linkRevision(request['expectedSelectionRevision']));
          case 'connect':
            await runtime.connect();
          case 'disconnect':
            _controlWithdrawing = true;
            await Future.wait(_work.toList());
            await runtime.disconnect();
          case 'shutdown':
            _controlWithdrawing = true;
            await Future.wait(_work.toList());
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
