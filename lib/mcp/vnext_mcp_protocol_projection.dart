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
  /// is actually built. The default Bridge refuses first; its explicit human
  /// wait profile permits bounded text encoding before App approval.
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
    _encodedBudget(submission, 1, <int>[GeneratedLimits.submissionBytes]);
    final encoded = jsonEncode(submission);
    if (utf8.encode(encoded).length > GeneratedLimits.submissionBytes) {
      throw const FormatException('invalidRequest');
    }
    return {'submissionJson': encoded, 'externalRequestId': null};
  }

  static void _encodedBudget(Object? value, int depth, List<int> budget) {
    void take(int count) {
      budget[0] -= count;
      if (budget[0] < 0) throw const FormatException('invalidRequest');
    }

    if (depth > _maxDepth) throw const FormatException('invalidRequest');
    if (value is String) {
      take(2);
      for (var i = 0; i < value.length; i++) {
        final c = value.codeUnitAt(i);
        if (c >= 0xd800 && c <= 0xdbff) {
          if (++i >= value.length ||
              value.codeUnitAt(i) < 0xdc00 ||
              value.codeUnitAt(i) > 0xdfff) {
            throw const FormatException('invalidRequest');
          }
          take(4);
        } else if (c >= 0xdc00 && c <= 0xdfff) {
          throw const FormatException('invalidRequest');
        } else if (c == 34 || c == 92 || const [8, 9, 10, 12, 13].contains(c)) {
          take(2);
        } else {
          take(c < 32
              ? 6
              : c < 128
                  ? 1
                  : c < 2048
                      ? 2
                      : 3);
        }
      }
    } else if (value is List) {
      take(2 + (value.isEmpty ? 0 : value.length - 1));
      for (final item in value) {
        _encodedBudget(item, depth + 1, budget);
      }
    } else if (value is Map) {
      take(2 + (value.isEmpty ? 0 : value.length - 1));
      for (final entry in value.entries) {
        final key = entry.key;
        if (key is! String) throw const FormatException('invalidRequest');
        _encodedBudget(key, depth + 1, budget);
        take(1);
        _encodedBudget(entry.value, depth + 1, budget);
      }
    } else if (value == null ||
        value is bool ||
        value is num && value.isFinite) {
      take(value.toString().length);
    } else {
      throw const FormatException('invalidRequest');
    }
  }

  /// Selectors are carried by v3 and resolved only by trusted App composition.
  bool get needsAppBinding =>
      contextRef != null || contextKind != VnextMcpContextKind.read;

  /// STAGE classification; the default Bridge refuses before payload encoding.
  bool get bridgeStageBlocked => contextKind == VnextMcpContextKind.stage;

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
          submission.cast<String, Object?>(),
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
        'schemaVersion': 3,
        'type': 'command',
        'capability': capability,
        'input': {
          ...input,
          if (contextRef != null) 'contextRef': contextRef,
          if (contextKind == VnextMcpContextKind.proposalLifecycle)
            'submissionKey': submissionKey,
        },
      });

  UntrustedIpcEnvelope request(String id) =>
      decodeFrame(IpcEnvelopeCodec.encodeRequest(id, payload));

  /// Strict deep P10 validation plus operation/id correlation. A valid result
  /// for some other operation or original key must never become this success.
  Map<String, Object?> response(UntrustedIpcEnvelope envelope, String id) {
    final decoded = IpcCommandResponseCodec.decode(envelope);
    final preCommandFailure = decoded['capability'] == null &&
        decoded['schemaVersion'] == 1 &&
        decoded['error'] != null;
    if (envelope.requestId != id ||
        (!preCommandFailure &&
            (decoded['schemaVersion'] != 3 ||
                decoded['capability'] != capability))) {
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
