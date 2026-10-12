import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/external/ipc_command_projection.dart';
import 'package:shiroha_quiz/data/external/ipc_envelope_codec.dart';

UntrustedIpcEnvelope resultEnvelope(String payload) => IpcEnvelopeDecoder()
    .consume(IpcEnvelopeCodec.encodeResponse('response-id', payload))
    .envelope!;
Map<String, Object?> result(String capability, Object? data) => {
      'schemaVersion': 1,
      'type': 'result',
      'capability': capability,
      'data': data,
      'error': null,
    };

void main() {
  final ref = 'a' * 43;
  final chunk = <String, Object?>{
    'content': 'Allowed snippet',
    'contentKind': 'paragraph',
    'locator': 'part:0/window:0',
    'chunkOrdinal': 0,
    'partOrdinal': 0,
    'windowOrdinal': 0,
    'pageNumber': null,
  };
  Map<String, Object?> page(List<Object?> items) => {
        'items': items,
        'nextCursor': null,
        'hasMore': false,
        'unsupportedExcluded': false,
        'startsAtDocumentBeginning': false,
      };
  final detail = <String, Object?>{
    'kind': 'short_answer',
    'stem': [
      {'type': 'text', 'text': 'Question'}
    ],
    'options': [],
    'answer': null,
    'explanation': [],
    'sourceKind': 'typed',
  };
  final stage = <String, Object?>{
    'proposalId': '00000000-0000-4000-8000-000000000001',
    'submissionKey': 'original-key',
    'publication': 'STAGED',
    'formalCommit': 'NOT_REPORTED',
  };
  final samples = <String, Map<String, Object?>>{
    'external_list_targets': {
      'items': [
        {
          'targetRef': ref,
          'bankName': 'bank',
          'projectId': null,
          'folderName': null
        }
      ],
      'nextCursor': null
    },
    'external_create_read_context': {'contextRef': ref},
    'external_search_questions': {
      'items': [
        {
          'questionRef': ref,
          'kind': 'short_answer',
          'stemPreview': 'Safe',
          'hasAnswer': false,
          'hasExplanation': true,
          'sourceKind': 'legacy'
        }
      ],
      'nextCursor': null
    },
    'external_get_question_detail': detail,
    'external_list_file_selections': page([
      {'fileRef': ref, 'selectionOrdinal': 0}
    ]),
    'external_create_file_context': {'contextRef': ref},
    'external_retrieve_file_content': page([
      {'passageRef': ref, ...chunk}
    ]),
    'external_get_file_passage': page([chunk]),
    'external_stage_generated_questions': stage,
    'external_reconcile_generated_stage': stage,
  };
  for (final entry in samples.entries) {
    test('${entry.key} exact response whitelist roundtrips', () {
      final message = result(entry.key, entry.value);
      final frame =
          IpcEnvelopeCodec.encodeResponse('response-id', jsonEncode(message));
      final envelope = IpcEnvelopeDecoder().consume(frame).envelope!;
      expect(IpcCommandResponseCodec.decode(envelope), message);
      expect(IpcEnvelopeCodec.encode(envelope), frame);
    });
    test('${entry.key} rejects unknown response data field', () {
      final message = result(entry.key, {
        ...entry.value,
        'authorization': {'recipient': 'forged'}
      });
      expect(
          () => IpcCommandResponseCodec.decode(
              resultEnvelope(jsonEncode(message))),
          throwsA(isA<IpcCommandSchemaException>()));
    });
  }

  test(
      'response schema, kind, duplicate fields and root types reject independently',
      () {
    final message = jsonEncode(result('external_get_question_detail', detail));
    for (final text in [
      '{',
      'null',
      message.replaceFirst('"schemaVersion":1', '"schemaVersion":2'),
      message.replaceFirst('"schemaVersion":1', '"schemaVersion":1.0'),
      message.replaceFirst(
          '"schemaVersion":1', '"schemaVersion":1,"schemaVersion":1'),
      message.replaceFirst(
          '"schemaVersion":1', '"schemaVersion":1,"schema\\u0056ersion":1'),
      message.replaceFirst('"type":"result"', '"type":"command"'),
      message.replaceFirst('"error":null', '"error":null,"receipt":{}'),
      message.replaceFirst('"error":null', '"error":"raw secret/path"'),
      message.replaceFirst('"error":null', '"error":"unavailable"'),
      message.replaceFirst('"data":{', '"data":null,"extra":{'),
      message.replaceFirst('"answer":null', '"answer":null,"answer":[]'),
    ]) {
      expect(() => IpcCommandResponseCodec.decode(resultEnvelope(text)),
          throwsA(isA<IpcCommandSchemaException>()));
    }
    expect(
        () => IpcCommandResponseCodec.decode(IpcEnvelopeDecoder()
            .consume(IpcEnvelopeCodec.encodeRequest('r', message))
            .envelope!),
        throwsA(isA<IpcCommandSchemaException>()));
  });

  test('detail preserves null/empty and only structural safe node types', () {
    final decoded = IpcCommandResponseCodec.decode(resultEnvelope(
        jsonEncode(result('external_get_question_detail', detail))));
    final data = decoded['data']! as Map;
    expect(data.containsKey('answer'), isTrue);
    expect(data['answer'], isNull);
    expect(data['explanation'], isEmpty);
    final admitted = {
      ...detail,
      'stem': [
        {'type': 'inline_math', 'latex': r'x^2'},
        {'type': 'block_math', 'latex': r'\frac{1}{2}'},
        {'type': 'unsupported'},
      ]
    };
    expect(
        () => IpcCommandResponseCodec.decode(resultEnvelope(
            jsonEncode(result('external_get_question_detail', admitted)))),
        returnsNormally);
    for (final node in [
      {'type': 'image', 'path': 'C:/private'},
      {'type': 'raw_fallback', 'payload': 'private'},
      {'type': 'unsupported', 'sourceId': 'private'},
      {'type': 'text', 'text': '\uD800'},
      {'type': 'text', 'text': null},
      {'type': 'inline_math', 'latex': 'x', 'extra': true},
    ]) {
      final invalid = {
        ...detail,
        'stem': [node]
      };
      expect(
          () => IpcCommandResponseCodec.decode(resultEnvelope(
              jsonEncode(result('external_get_question_detail', invalid)))),
          throwsA(isA<IpcCommandSchemaException>()));
    }
  });

  test(
      'passage/query/selection whitelists never serialize file/storage/source/evidence DTOs',
      () {
    for (final forbidden in [
      'fileId',
      'artifactId',
      'chunkId',
      'path',
      'sourceRef',
      'executionEvidence',
      'title',
      'heading',
      'authorization'
    ]) {
      final invalid = page([
        {...chunk, forbidden: 'private'}
      ]);
      expect(
          () => IpcCommandResponseCodec.decode(resultEnvelope(
              jsonEncode(result('external_get_file_passage', invalid)))),
          throwsA(isA<IpcCommandSchemaException>()));
    }
    for (final invalid in [
      {...chunk, 'pageNumber': 1.0},
      {...chunk, 'chunkOrdinal': -1},
      {...chunk, 'contentKind': 'raw_fallback'},
      {...chunk, 'passageRef': ref},
    ]) {
      expect(
          () => IpcCommandResponseCodec.decode(resultEnvelope(jsonEncode(
              result('external_get_file_passage', page([invalid]))))),
          throwsA(isA<IpcCommandSchemaException>()));
    }
    expect(
        () => IpcCommandResponseCodec.decode(resultEnvelope(jsonEncode(
            result('external_retrieve_file_content', page([chunk]))))),
        throwsA(isA<IpcCommandSchemaException>()));
  });

  test('response budgets reject complete oversized output, never truncate', () {
    final invalid = {
      ...detail,
      'stem': [
        {'type': 'text', 'text': 'x' * 32768}
      ]
    };
    expect(
        () => IpcCommandResponseCodec.decode(resultEnvelope(
            jsonEncode(result('external_get_question_detail', invalid)))),
        throwsA(isA<IpcCommandSchemaException>()));
    expect(
        () => IpcEnvelopeCodec.encodeResponse(
            'r', 'x' * (IpcEnvelopeLimits.responseBytes + 1)),
        throwsA(isA<IpcProtocolException>()));
    final responseFrame = IpcEnvelopeCodec.encodeResponse(
        'r', 'x' * IpcEnvelopeLimits.responseBytes);
    expect(IpcEnvelopeDecoder().consume(responseFrame).envelope!.payload.length,
        IpcEnvelopeLimits.responseBytes);
  });

  test('node totals and passage coverage cannot silently expand', () {
    final invalid = {
      ...detail,
      'stem': List.filled(300, {'type': 'unsupported'}),
      'answer': List.filled(300, {'type': 'unsupported'})
    };
    expect(
        () => IpcCommandResponseCodec.decode(resultEnvelope(
            jsonEncode(result('external_get_question_detail', invalid)))),
        throwsA(isA<IpcCommandSchemaException>()));
    for (final fields in [
      {'startsAtDocumentBeginning': true},
      {'hasMore': true},
      {'nextCursor': ref}
    ]) {
      final retrieval = {
        ...page([
          {'passageRef': ref, ...chunk}
        ]),
        ...fields
      };
      expect(
          () => IpcCommandResponseCodec.decode(resultEnvelope(
              jsonEncode(result('external_retrieve_file_content', retrieval)))),
          throwsA(isA<IpcCommandSchemaException>()));
    }
    final passage = {
      ...page([chunk]),
      'hasMore': true
    };
    expect(
        () => IpcCommandResponseCodec.decode(resultEnvelope(
            jsonEncode(result('external_get_file_passage', passage)))),
        throwsA(isA<IpcCommandSchemaException>()));
  });

  test(
      'STAGE status never invents formal COMMIT and errors use fixed vocabulary',
      () {
    for (final value in ['COMMITTED', 'committed', true, null]) {
      expect(
          () => IpcCommandResponseCodec.decode(resultEnvelope(jsonEncode(result(
              'external_stage_generated_questions',
              {...stage, 'formalCommit': value})))),
          throwsA(isA<IpcCommandSchemaException>()));
    }
    for (final code in [
      'unauthenticated',
      'invalidRequest',
      'capability.externalResponseLost',
      'responseEncodingFailed'
    ]) {
      final error = {
        'schemaVersion': 1,
        'type': 'result',
        'capability': null,
        'data': null,
        'error': code
      };
      expect(IpcCommandResponseCodec.decode(resultEnvelope(jsonEncode(error))),
          error);
    }
  });
}
