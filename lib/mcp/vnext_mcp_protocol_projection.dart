/// Shared seven-tool mapping. This describes requests, never App authority.
library;

import 'dart:convert';
import 'dart:typed_data';
import '../data/external/ipc_command_projection.dart';
import '../data/external/ipc_envelope_codec.dart';
import '../domain/generated_question/generated_question_contract.dart';
import 'vnext_mcp_server.dart';

enum VnextMcpContextKind { read, stage, proposalLifecycle }

/// Selectors must be resolved by the original App owners, under the exact
/// authenticated Session. None of these fields is an execution Context.
final class VnextMcpCommand {
  VnextMcpCommand._(this.capability, Map<String, Object?> input,
      {this.contextKind = VnextMcpContextKind.read,
      this.contextRef,
      this.submissionKey})
      : _input = input,
        _submission = null;

  VnextMcpCommand._stage(this.capability, Map<String, Object?> submission,
      {required this.contextRef, required this.submissionKey})
      : contextKind = VnextMcpContextKind.stage,
        _input = null,
        _submission = submission;

  final String capability;
  final VnextMcpContextKind contextKind;
  final String? contextRef, submissionKey;
  Map<String, Object?>? _input;
  final Map<String, Object?>? _submission;

  /// Classification is cheap; a STAGE payload is serialized only when a frame
  /// is actually built, i.e. after the App's exact-Session approval. The
  /// Bridge never materializes it because every STAGE call refuses first.
  Map<String, Object?> get input => _input ??= _boundedStageInput(_submission!);

  /// Frozen GeneratedQuestion admission bounds, applied before `jsonEncode`
  /// so an oversized or too deep submission allocates no encoded payload.
  static const _maxItems = 50, _maxDepth = 16;

  static Map<String, Object?> _boundedStageInput(
      Map<String, Object?> submission) {
    final items = submission['items'];
    if (items is List && items.length > _maxItems) {
      throw const FormatException('invalidRequest');
    }
    final budget = <int>[GeneratedLimits.submissionBytes];
    if (_exceedsBudget(submission, 1, budget)) {
      throw const FormatException('invalidRequest');
    }
    final encoded = jsonEncode(submission);
    if (utf8.encode(encoded).length > GeneratedLimits.submissionBytes) {
      throw const FormatException('invalidRequest');
    }
    return {'submissionJson': encoded, 'externalRequestId': null};
  }

  static bool _exceedsBudget(Object? value, int depth, List<int> budget) {
    if (depth > _maxDepth) return true;
    if (value is String) {
      budget[0] -= value.length;
    } else if (value is List) {
      budget[0] -= value.length;
      for (final item in value) {
        if (_exceedsBudget(item, depth + 1, budget)) return true;
      }
    } else if (value is Map) {
      for (final entry in value.entries) {
        final key = entry.key;
        budget[0] -= (key is String ? key.length : 0) + 4;
        if (_exceedsBudget(entry.value, depth + 1, budget)) return true;
      }
    } else {
      budget[0] -= 8;
    }
    return budget[0] < 0;
  }

  /// P10 has no wire field for these App-owned bindings. The current TLS Host
  /// accepts only a compiled, per-Session Context supplier, without selectors.
  bool get needsAppBinding =>
      contextRef != null || contextKind != VnextMcpContextKind.read;

  static VnextMcpCommand parse(String tool, Map<String, dynamic> arguments) {
    final schema = VnextMcpServer.inputSchemas[tool];
    if (schema == null) throw const FormatException('unsupportedCapability');
    final properties = schema['properties'] as Map;
    final required = schema['required'] as List;
    if (arguments.keys.any((key) => !properties.containsKey(key)) ||
        required.any((key) => !arguments.containsKey(key))) {
      throw const FormatException('invalidRequest');
    }
    final context = arguments['contextRef'] as String?;
    if (arguments.containsKey('contextRef') &&
        (context == null ||
            !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(context))) {
      throw const FormatException('invalidRequest');
    }
    if (tool == 'get_question_proposal') {
      return VnextMcpCommand._('external_get_proposal_lifecycle', {},
          contextKind: VnextMcpContextKind.proposalLifecycle,
          submissionKey: arguments['submissionKey'] as String);
    }
    if (tool == 'propose_generated_questions') {
      final submission = arguments['submission'] as Map;
      return VnextMcpCommand._stage('external_stage_generated_questions',
          Map<String, Object?>.from(submission),
          contextRef: context,
          submissionKey: submission['submissionKey'] as String);
    }
    if (tool == 'open_generation_context') {
      if (arguments.containsKey('fileRefs')) {
        if (context == null || arguments.length != 2) {
          throw const FormatException('invalidRequest');
        }
        return VnextMcpCommand._(
            'external_create_file_context', {'fileRefs': arguments['fileRefs']},
            contextRef: context);
      }
      if (context != null) {
        if (arguments.length != 1) {
          throw const FormatException('invalidRequest');
        }
        return VnextMcpCommand._('external_list_file_selections', {},
            contextRef: context);
      }
      if (arguments.containsKey('targetRef')) {
        if (arguments.length != 1) {
          throw const FormatException('invalidRequest');
        }
        return VnextMcpCommand._('external_create_read_context',
            {'targetRef': arguments['targetRef']});
      }
      return VnextMcpCommand._('external_list_targets', {
        'pageSize': arguments['pageSize'] ?? 20,
        'cursor': arguments['cursor'],
      });
    }
    if (context == null) throw const FormatException('invalidRequest');
    return switch (tool) {
      'search_questions' => VnextMcpCommand._(
          'external_search_questions',
          {
            'query': arguments['query'],
            'pageSize': arguments['pageSize'] ?? 20,
            'cursor': arguments['cursor'],
          },
          contextRef: context),
      'get_question_detail' => VnextMcpCommand._('external_get_question_detail',
          {'questionRef': arguments['questionRef']},
          contextRef: context),
      'retrieve_file_content' => VnextMcpCommand._(
          'external_retrieve_file_content',
          {'query': arguments['query'], 'limit': arguments['limit'] ?? 8},
          contextRef: context),
      'get_file_passage' => VnextMcpCommand._(
          'external_get_file_passage',
          {
            'passageRef': arguments['passageRef'],
            'cursor': arguments['cursor'],
          },
          contextRef: context),
      _ => throw const FormatException('unsupportedCapability'),
    };
  }

  String get payload => jsonEncode({
        'schemaVersion':
            contextKind == VnextMcpContextKind.proposalLifecycle ? 2 : 1,
        'type': 'command',
        'capability': capability,
        'input': input,
      });

  UntrustedIpcEnvelope request(String id) =>
      decodeFrame(IpcEnvelopeCodec.encodeRequest(id, payload));

  /// Strict deep P10 validation plus operation/id correlation. A valid result
  /// for some other operation or original key must never become this success.
  Map<String, Object?> response(UntrustedIpcEnvelope envelope, String id) {
    final decoded = IpcCommandResponseCodec.decode(envelope);
    if (envelope.requestId != id ||
        (decoded['capability'] != capability &&
            !(decoded['capability'] == null && decoded['error'] != null))) {
      throw const FormatException('invalidResult');
    }
    final data = decoded['data'];
    if (submissionKey != null &&
        data is Map &&
        data['submissionKey'] != submissionKey) {
      throw const FormatException('invalidResult');
    }
    return {
      'profileVersion': 2,
      'data': data,
      'error': decoded['error'],
    };
  }

  static UntrustedIpcEnvelope decodeFrame(Uint8List bytes) {
    final decoder = IpcEnvelopeDecoder();
    try {
      final step = decoder.consume(bytes);
      decoder.finish();
      if (step.consumed != bytes.length || step.envelope == null) {
        throw const FormatException('invalidResult');
      }
      return step.envelope!;
    } finally {
      decoder.close();
    }
  }
}
