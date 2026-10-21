/// Shared seven-tool mapping. This describes requests, never App authority.
library;

import 'dart:convert';
import 'dart:typed_data';
import '../data/external/ipc_command_projection.dart';
import '../data/external/ipc_envelope_codec.dart';
import 'vnext_mcp_server.dart';

enum VnextMcpContextKind { read, stage, proposalLifecycle }

/// Selectors must be resolved by the original App owners, under the exact
/// authenticated Session. None of these fields is an execution Context.
final class VnextMcpCommand {
  const VnextMcpCommand._(this.capability, this.input,
      {this.contextKind = VnextMcpContextKind.read,
      this.contextRef,
      this.submissionKey});

  final String capability;
  final Map<String, Object?> input;
  final VnextMcpContextKind contextKind;
  final String? contextRef, submissionKey;

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
      return VnextMcpCommand._(
          'external_stage_generated_questions',
          {
            'submissionJson': jsonEncode(submission),
            'externalRequestId': null,
          },
          contextKind: VnextMcpContextKind.stage,
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
