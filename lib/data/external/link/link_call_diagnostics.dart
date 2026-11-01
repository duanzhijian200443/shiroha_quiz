import 'dart:convert';

import 'link_values.dart';

// Ordinals are a versioned, fixed diagnostic projection, never wire fields.
enum LinkCallStage {
  admission,
  attach,
  ipcSend,
  ipcReceive,
  backendCall,
  resultValidate,
  outputSend,
  deliveryAck
}

enum LinkCallOutcome { unseen, entered, succeeded, rejected, failed, unknown }

enum LinkCallCause {
  none,
  unknown,
  unavailable,
  busy,
  invalidFrame,
  invalidResult,
  deviceMismatch,
  timeout,
  clientFailure,
  prePortRejected,
  invalidParams,
  invalidRequest,
  methodNotFound,
  internalError,
  eof,
  sendFailed,
  receiveFailed,
  resultMissing,
  resultShape,
  resultProfile,
  resultSource,
  resultData,
  resultErrorType,
  resultErrorFlag
}

typedef LinkCallObserver = void Function(LinkCallTrace);

enum LinkLifecycleCheckpoint {
  transportOnclose,
  portCloseEnter,
  portCloseSettled,
  captureFinishEnter
}

enum LinkLifecycleOutcome { observed, completed, failed }

typedef LinkLifecycleObserver = void Function(
    LinkLifecycleCheckpoint, LinkLifecycleOutcome);

/// Only bounded, non-secret projections survive beyond the original callback.
final class LinkCallDiagnostics {
  LinkCallDiagnostics(this.observer,
      {required this.frontend, this.stageObserved, this.formatVersion = 1});
  final LinkCallObserver observer;
  final bool frontend;
  final int formatVersion;
  // In-memory barrier observation; never writes an event or changes a stage.
  final void Function(int, LinkCallStage, LinkCallOutcome, LinkCallCause)?
      stageObserved;
  final _active = <LinkCallTrace>{};
  int observed = 0, finalized = 0, unassociated = 0;
  bool incomplete = false;
  static const maxCalls = 8;
  static const closureMaxCalls = 5;
  int get callLimit => formatVersion == 2 ? closureMaxCalls : maxCalls;
  static const tools = [
    'unknown',
    'open_context',
    'list_question_banks',
    'get_study_overview',
    'get_due_review_summary',
    'get_weak_questions',
    'search_questions',
    'get_question_detail',
    'retrieve_file_content',
    'get_file_passage',
    'get_question_proposal'
  ];
  static const fields = [
    'contextRef',
    'targetRef',
    'pageSize',
    'cursor',
    'fileRefs',
    'scope',
    'query',
    'questionRef',
    'timezone',
    'from',
    'to',
    'limit',
    'passageRef',
    'submissionKey'
  ];
  static const schemas = <String, List<String>>{
    'open_context': [
      'contextRef',
      'targetRef',
      'pageSize',
      'cursor',
      'fileRefs',
      'scope'
    ],
    'list_question_banks': ['contextRef', 'pageSize', 'cursor'],
    'get_study_overview': ['contextRef', 'timezone'],
    'get_due_review_summary': ['contextRef', 'timezone', 'from', 'to'],
    'get_weak_questions': ['contextRef', 'pageSize', 'cursor'],
    'search_questions': ['contextRef', 'query', 'pageSize', 'cursor'],
    'get_question_detail': ['contextRef', 'questionRef'],
    'retrieve_file_content': ['contextRef', 'query', 'limit'],
    'get_file_passage': ['contextRef', 'passageRef', 'cursor'],
    'get_question_proposal': ['submissionKey'],
  };

  LinkCallTrace? begin(Object? tool, Object? arguments) {
    try {
      if (observed >= callLimit) {
        incomplete = true;
        return null;
      }
      final trace = LinkCallTrace._(
          this, ++observed, tools.indexOf(tool is String ? tool : ''));
      if (trace.tool < 1) {
        trace.tool = 0;
        incomplete = true;
      }
      if (frontend) {
        final keys = schemas[tool] ?? const <String>[];
        final map = arguments is Map ? arguments : null;
        trace.argumentType = _type(arguments);
        var known = 0;
        for (final key in keys) {
          final present = map?.containsKey(key) ?? false;
          if (present) known++;
          final value = present ? map![key] : null;
          final length = value is String
              ? value.length
              : value is List
                  ? value.length
                  : value is Map
                      ? value.length
                      : 0;
          trace.shape.add([
            fields.indexOf(key),
            present ? 1 : 0,
            present ? _type(value) : 0,
            length.clamp(0, 256),
            length > 256 ? 1 : 0
          ]);
        }
        trace.unknownArguments = ((map?.length ?? 0) - known).clamp(0, 256);
      }
      _active.add(trace);
      return trace;
    } catch (_) {
      incomplete = true;
      return null;
    }
  }

  static int _type(Object? value) => switch (value) {
        null => 1,
        String() => 2,
        bool() => 3,
        int() => 4,
        num() => 5,
        List() => 6,
        Map() => 7,
        _ => 8,
      };
  void unbound() {
    unassociated = (unassociated + 1).clamp(0, 256);
    incomplete = true;
  }

  void finish(LinkCallTrace? trace) {
    if (trace == null) return;
    if (!_active.remove(trace)) {
      incomplete = true;
      return;
    }
    trace._finished = true;
    finalized++;
    try {
      observer(trace);
    } catch (_) {
      incomplete = true;
    }
  }

  void close() {
    if (_active.isNotEmpty) incomplete = true;
    for (final trace in _active.toList()) {
      finish(trace);
    }
  }
}

/// Mutable only while the one original call is observed; contains no arguments.
final class LinkCallTrace {
  LinkCallTrace._(this.diagnostics, this.ordinal, this.tool);
  final LinkCallDiagnostics diagnostics;
  final int ordinal;
  int tool, argumentType = 0, unknownArguments = 0;
  final shape = <List<int>>[];
  final stages = List.generate(8, (_) => [0, 0]);
  String? runId, connectionId, leaseId;
  int? callId, routeGeneration, selectionRevision;
  LinkOwnerReference? owner;
  bool _finished = false;

  void stage(LinkCallStage stage, LinkCallOutcome outcome,
      [LinkCallCause cause = LinkCallCause.none]) {
    if (_finished) {
      diagnostics.incomplete = true;
      return;
    }
    stages[stage.index] = [outcome.index, cause.index];
    try {
      diagnostics.stageObserved?.call(ordinal, stage, outcome, cause);
    } catch (_) {
      diagnostics.incomplete = true;
    }
  }

  void bind(
      {String? run,
      String? connection,
      int? call,
      String? lease,
      LinkLease? originalLease,
      LinkOwnerReference? originalOwner}) {
    if (_finished) {
      diagnostics.incomplete = true;
      return;
    }
    runId = run ?? runId;
    connectionId = connection ?? connectionId;
    callId = call ?? callId;
    leaseId = lease ?? originalLease?.leaseId ?? leaseId;
    routeGeneration = originalLease?.routeGeneration ?? routeGeneration;
    selectionRevision = originalLease?.selectionRevision ?? selectionRevision;
    owner = originalOwner ?? owner;
  }

  String encode(int sequence) {
    for (final token in [
      runId,
      connectionId,
      leaseId,
      owner?.resourceId,
      owner?.processStarted,
      owner?.slotRef
    ]) {
      if (token != null) linkToken(token);
    }
    if (owner != null && owner!.runId != runId) throw const FormatException();
    for (final number in [
      callId,
      routeGeneration,
      selectionRevision,
      owner?.processId
    ]) {
      if (number != null) linkRevision(number);
    }
    return jsonEncode({
      'v': diagnostics.formatVersion,
      'e': 'call',
      'p': diagnostics.frontend ? 'f' : 'l',
      's': sequence,
      'n': ordinal,
      't': tool,
      'r': runId,
      'c': connectionId,
      'i': callId,
      'l': leaseId,
      'g': routeGeneration,
      'q': selectionRevision,
      'o': owner == null
          ? null
          : [
              owner!.resourceId,
              owner!.processId,
              owner!.processStarted,
              owner!.slotRef
            ],
      if (diagnostics.frontend) ...{
        'a': shape,
        'at': argumentType,
        'u': unknownArguments
      },
      'x': stages
    });
  }
}
