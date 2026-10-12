import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/external/ipc_envelope_codec.dart';
import 'package:shiroha_quiz/domain/generated_question/generated_question_contract.dart';

Matcher failure(IpcProtocolFailure value) => throwsA(
    isA<IpcProtocolException>().having((e) => e.failure, 'failure', value));

Uint8List rawFrame({
  int kind = 1,
  int version = 1,
  int encoding = 1,
  int flags = 0,
  String id = 'a',
  List<int> body = const [120],
  int? length,
}) {
  final idBytes = utf8.encode(id);
  final frame = Uint8List(16 + idBytes.length + body.length);
  frame.setRange(0, 4, const [83, 72, 73, 80]);
  frame[4] = version;
  frame[5] = kind;
  frame[6] = encoding;
  frame[7] = flags;
  frame[8] = idBytes.length;
  ByteData.sublistView(frame).setUint32(12, length ?? body.length);
  frame.setRange(16, 16 + idBytes.length, idBytes);
  frame.setRange(16 + idBytes.length, frame.length, body);
  return frame;
}

List<UntrustedIpcEnvelope> consumeAll(
    IpcEnvelopeDecoder decoder, Uint8List bytes) {
  final results = <UntrustedIpcEnvelope>[];
  var offset = 0;
  while (offset < bytes.length) {
    final step = decoder.consume(bytes, offset: offset);
    expect(step.consumed, greaterThan(0));
    offset += step.consumed;
    if (step.envelope != null) results.add(step.envelope!);
  }
  return results;
}

void cleared(IpcEnvelopeDecoder decoder) {
  expect(decoder.isClosed, isTrue);
  expect(decoder.bufferedBytes, 0);
  expect(decoder.allocatedPayloadBytes, 0);
  expect(decoder.retainedByteCapacity, 80);
}

void main() {
  test('exact request wire vector and independent IPC version', () {
    final frame = IpcEnvelopeCodec.encodeRequest('A_9-', '中𝄞\n');
    expect(frame, [
      83,
      72,
      73,
      80,
      1,
      1,
      1,
      0,
      4,
      0,
      0,
      0,
      0,
      0,
      0,
      8,
      65,
      95,
      57,
      45,
      0xe4,
      0xb8,
      0xad,
      0xf0,
      0x9d,
      0x84,
      0x9e,
      10,
    ]);
    final decoder = IpcEnvelopeDecoder();
    final step = decoder.consume(frame);
    expect(step.consumed, frame.length);
    expect(step.envelope!.version, 1);
    expect(step.envelope!.kind, IpcMessageKind.request);
    expect(step.envelope!.requestId, 'A_9-');
    expect(step.envelope!.payload, '中𝄞\n');
    expect(IpcEnvelopeCodec.encode(step.envelope!), frame);
    expect(decoder.bufferedBytes, 0);
    decoder.finish();
    cleared(decoder);
  });

  test('request/response/error coalescing stops at one exact boundary', () {
    final frames = [
      IpcEnvelopeCodec.encodeRequest('same-id', 'request'),
      IpcEnvelopeCodec.encodeResponse('same-id', 'response'),
      IpcEnvelopeCodec.encodeError(IpcProtocolFailure.unsupportedVersion),
    ];
    final bytes = Uint8List.fromList(frames.expand((f) => f).toList());
    final decoder = IpcEnvelopeDecoder();
    final first = decoder.consume(bytes);
    expect(first.consumed, frames.first.length);
    expect(first.envelope!.kind, IpcMessageKind.request);
    expect(decoder.bufferedBytes, 0);
    final others =
        consumeAll(decoder, Uint8List.sublistView(bytes, first.consumed));
    expect(others.map((e) => e.kind),
        [IpcMessageKind.response, IpcMessageKind.protocolError]);
    expect(others.first.payload, 'response');
    expect(others.last.requestId, isNull);
    expect(others.last.payload, 'unsupportedVersion');
    decoder.finish();
  });

  test('forty continuous frames do not need an internal queue or batch cap',
      () {
    final bytes = Uint8List.fromList(
        List.generate(40, (i) => IpcEnvelopeCodec.encodeRequest('r$i', 'p$i'))
            .expand((f) => f)
            .toList());
    final decoder = IpcEnvelopeDecoder();
    final messages = consumeAll(decoder, bytes);
    expect(messages.map((m) => m.requestId), List.generate(40, (i) => 'r$i'));
    expect(messages.map((m) => m.payload), List.generate(40, (i) => 'p$i'));
    expect(decoder.peakPayloadBytes, 3);
    decoder.finish();
  });

  test('every split point withholds partial ID and multibyte payload', () {
    final frame = IpcEnvelopeCodec.encodeRequest('r' * 64, '中🙂\n\uFEFF');
    for (var split = 0; split < frame.length; split++) {
      final decoder = IpcEnvelopeDecoder();
      final first = decoder.consume(Uint8List.sublistView(frame, 0, split));
      expect(first.consumed, split);
      expect(first.envelope, isNull, reason: 'split $split');
      final second = decoder.consume(Uint8List.sublistView(frame, split));
      expect(second.envelope!.payload, '中🙂\n\uFEFF');
      expect(second.envelope!.requestId, 'r' * 64);
      expect(second.consumed, frame.length - split);
      decoder.finish();
    }
  });

  test('one-byte chunks publish only after the final declared byte', () {
    final frame = IpcEnvelopeCodec.encodeResponse('r', '中🙂');
    final decoder = IpcEnvelopeDecoder();
    for (var i = 0; i < frame.length; i++) {
      final step = decoder.consume(Uint8List.sublistView(frame, i, i + 1));
      expect(step.consumed, 1);
      if (i < frame.length - 1) {
        expect(step.envelope, isNull);
      } else {
        expect(step.envelope!.kind, IpcMessageKind.response);
        expect(step.envelope!.payload, '中🙂');
      }
    }
    decoder.finish();
  });

  test('opaque payload preserves leading/interior BOM, NUL and JSON text', () {
    for (final text in [
      '\uFEFF',
      '\uFEFF\uFEFFx',
      'x\uFEFF',
      '\u0000',
      '{"duplicate":1,"duplicate":2}',
      'not JSON',
      '[1,2]'
    ]) {
      final encoded = IpcEnvelopeCodec.encodeRequest('r', text);
      final decoder = IpcEnvelopeDecoder();
      final decoded = decoder.consume(encoded).envelope!;
      expect(decoded.payload, text);
      expect(IpcEnvelopeCodec.encode(decoded), encoded);
      decoder.finish();
    }
  });

  test('caller byte mutation cannot alter partial or completed values', () {
    final frame = IpcEnvelopeCodec.encodeRequest('r', 'hello');
    final decoder = IpcEnvelopeDecoder();
    expect(
        decoder.consume(Uint8List.sublistView(frame, 0, 19)).envelope, isNull);
    frame.fillRange(0, 19, 0);
    final result = decoder.consume(Uint8List.sublistView(frame, 19)).envelope!;
    frame.fillRange(0, frame.length, 0);
    expect(result.requestId, 'r');
    expect(result.payload, 'hello');
    expect(decoder.retainedByteCapacity, 80);
  });

  group('header admission before payload allocation', () {
    final cases = <String, (Uint8List, IpcProtocolFailure)>{
      'magic': (
        Uint8List.fromList(rawFrame())..[0] = 0,
        IpcProtocolFailure.invalidFrame
      ),
      'version zero': (
        rawFrame(version: 0),
        IpcProtocolFailure.unsupportedVersion
      ),
      'future version': (
        rawFrame(version: 2),
        IpcProtocolFailure.unsupportedVersion
      ),
      'unknown request kind': (
        rawFrame(kind: 0),
        IpcProtocolFailure.unsupportedMessage
      ),
      'unknown kind': (
        rawFrame(kind: 255),
        IpcProtocolFailure.unsupportedMessage
      ),
      'undeclared encoding': (
        rawFrame(encoding: 0),
        IpcProtocolFailure.unsupportedEncoding
      ),
      'unknown encoding': (
        rawFrame(encoding: 255),
        IpcProtocolFailure.unsupportedEncoding
      ),
      'feature flag': (
        rawFrame(flags: 1),
        IpcProtocolFailure.unsupportedFeature
      ),
      for (final offset in [9, 10, 11])
        'reserved $offset': (
          Uint8List.fromList(rawFrame())..[offset] = 1,
          IpcProtocolFailure.unsupportedFeature
        ),
      'empty id': (rawFrame(id: ''), IpcProtocolFailure.invalidId),
      'oversized id': (rawFrame(id: 'x' * 65), IpcProtocolFailure.invalidId),
      'error cannot echo id': (rawFrame(kind: 3), IpcProtocolFailure.invalidId),
      'zero body': (rawFrame(length: 0), IpcProtocolFailure.invalidLength),
      'signed negative': (
        rawFrame(length: 0x80000000),
        IpcProtocolFailure.invalidLength
      ),
      'overflow representation': (
        rawFrame(length: 0xffffffff),
        IpcProtocolFailure.invalidLength
      ),
      'largest signed value': (
        rawFrame(length: 0x7fffffff),
        IpcProtocolFailure.resourceLimit
      ),
      'request ceiling plus one': (
        rawFrame(length: IpcEnvelopeLimits.requestBytes + 1),
        IpcProtocolFailure.resourceLimit
      ),
      'response ceiling plus one': (
        rawFrame(kind: 2, length: IpcEnvelopeLimits.responseBytes + 1),
        IpcProtocolFailure.resourceLimit
      ),
      'error ceiling plus one': (
        rawFrame(kind: 3, id: '', length: 33),
        IpcProtocolFailure.resourceLimit
      ),
    };
    for (final entry in cases.entries) {
      test(entry.key, () {
        final decoder = IpcEnvelopeDecoder();
        final (bytes, expected) = entry.value;
        expect(() => decoder.consume(Uint8List.sublistView(bytes, 0, 16)),
            failure(expected));
        cleared(decoder);
        expect(decoder.peakPayloadBytes, 0);
        expect(() => decoder.consume(rawFrame()),
            failure(IpcProtocolFailure.closed));
      });
    }
  });

  test('invalid ID bytes reject before payload allocation, without coercion',
      () {
    for (final id in ['a b', 'a/b', 'a.b', '\n', '中', '\u0000']) {
      final decoder = IpcEnvelopeDecoder();
      expect(() => decoder.consume(rawFrame(id: id)),
          failure(IpcProtocolFailure.invalidId));
      cleared(decoder);
      expect(decoder.peakPayloadBytes, 0);
      expect(() => IpcEnvelopeCodec.encodeRequest(id, 'x'),
          failure(IpcProtocolFailure.invalidId));
    }
    for (final id in ['', 'a' * 65]) {
      expect(() => IpcEnvelopeCodec.encodeResponse(id, 'x'),
          failure(IpcProtocolFailure.invalidId));
    }
  });

  test('every nonempty incomplete prefix rejects on EOF and releases storage',
      () {
    final frame = IpcEnvelopeCodec.encodeRequest('abc', '中🙂');
    for (var end = 1; end < frame.length; end++) {
      final decoder = IpcEnvelopeDecoder();
      expect(decoder.consume(Uint8List.sublistView(frame, 0, end)).envelope,
          isNull);
      expect(() => decoder.finish(), failure(IpcProtocolFailure.truncated));
      cleared(decoder);
    }
  });

  test('tail garbage is not ignored, even after a complete valid frame', () {
    for (final count in [1, 15, 16, 32]) {
      final encoded = IpcEnvelopeCodec.encodeRequest('r', 'valid');
      final bytes = Uint8List.fromList([...encoded, ...List.filled(count, 0)]);
      final decoder = IpcEnvelopeDecoder();
      final first = decoder.consume(bytes);
      expect(first.envelope!.payload, 'valid');
      expect(first.consumed, encoded.length);
      if (count >= 16) {
        expect(() => decoder.consume(bytes, offset: first.consumed),
            failure(IpcProtocolFailure.invalidFrame));
      } else {
        expect(decoder.consume(bytes, offset: first.consumed).envelope, isNull);
        expect(() => decoder.finish(), failure(IpcProtocolFailure.truncated));
      }
      cleared(decoder);
    }
  });

  group('strict UTF-8 failures', () {
    final bad = <List<int>>[
      [0x80],
      [0xc0, 0xaf],
      [0xc2],
      [0xe0, 0x80, 0x80],
      [0xed, 0xa0, 0x80],
      [0xf0, 0x80, 0x80, 0x80],
      [0xf4, 0x90, 0x80, 0x80],
      [0xff],
      [0xe2, 0x28, 0xa1],
    ];
    for (var i = 0; i < bad.length; i++) {
      test('invalid sequence $i', () {
        final decoder = IpcEnvelopeDecoder();
        expect(() => decoder.consume(rawFrame(body: bad[i])),
            failure(IpcProtocolFailure.invalidUtf8));
        cleared(decoder);
      });
    }
  });

  test('encoder refuses unpaired surrogates instead of silent replacement', () {
    for (final units in [
      [0xd800],
      [0xdc00],
      [0xd800, 65],
      [65, 0xdbff]
    ]) {
      expect(
          () =>
              IpcEnvelopeCodec.encodeRequest('r', String.fromCharCodes(units)),
          failure(IpcProtocolFailure.invalidUtf8));
    }
  });

  test('fixed protocol errors cannot carry arbitrary content or authority', () {
    for (final value in IpcProtocolFailure.values) {
      final frame = IpcEnvelopeCodec.encodeError(value);
      final decoder = IpcEnvelopeDecoder();
      final result = decoder.consume(frame).envelope!;
      expect(result.kind, IpcMessageKind.protocolError);
      expect(result.requestId, isNull);
      expect(result.payload, value.name);
      expect(IpcEnvelopeCodec.encode(result), frame);
      decoder.finish();
    }
    final decoder = IpcEnvelopeDecoder();
    expect(
        () => decoder
            .consume(rawFrame(kind: 3, id: '', body: utf8.encode('secret'))),
        failure(IpcProtocolFailure.invalidPayload));
    cleared(decoder);
  });

  test('byte ceilings agree between encoder and decoder without truncation',
      () {
    for (final (kind, limit) in [
      (IpcMessageKind.request, IpcEnvelopeLimits.requestBytes),
      (IpcMessageKind.response, IpcEnvelopeLimits.responseBytes),
    ]) {
      for (final count in [limit - 1, limit]) {
        final text = 'x' * count;
        final frame = kind == IpcMessageKind.request
            ? IpcEnvelopeCodec.encodeRequest('r' * 64, text)
            : IpcEnvelopeCodec.encodeResponse('r' * 64, text);
        expect(frame.length, 16 + 64 + count);
        expect(ByteData.sublistView(frame).getUint32(12), count);
        final decoder = IpcEnvelopeDecoder();
        expect(decoder.consume(frame).envelope!.payload, text);
        expect(decoder.peakPayloadBytes, count);
        expect(decoder.retainedByteCapacity, 80);
      }
      final tooLarge = 'x' * (limit + 1);
      expect(
          () => kind == IpcMessageKind.request
              ? IpcEnvelopeCodec.encodeRequest('r', tooLarge)
              : IpcEnvelopeCodec.encodeResponse('r', tooLarge),
          failure(IpcProtocolFailure.resourceLimit));
    }
    expect(() => IpcEnvelopeCodec.encodeRequest('r', ''),
        failure(IpcProtocolFailure.invalidLength));
  });

  test('multibyte boundary uses bytes, not character count', () {
    const limit = IpcEnvelopeLimits.responseBytes;
    final exact = '${'中' * (limit ~/ 3)}${'x' * (limit % 3)}';
    final frame = IpcEnvelopeCodec.encodeResponse('r', exact);
    expect(ByteData.sublistView(frame).getUint32(12), limit);
    expect(IpcEnvelopeDecoder().consume(frame).envelope!.payload, exact);
    expect(() => IpcEnvelopeCodec.encodeResponse('r', '${exact}x'),
        failure(IpcProtocolFailure.resourceLimit));
    expect(() => IpcEnvelopeCodec.encodeResponse('r', '🙂' * (limit ~/ 4 + 1)),
        failure(IpcProtocolFailure.resourceLimit));
  });

  test('full inherited STAGE/File budgets and worst escape representation fit',
      () {
    expect(IpcEnvelopeLimits.requestBytes,
        6 * GeneratedLimits.submissionBytes + 32768);
    final raw = '\u0000' * GeneratedLimits.submissionBytes;
    final escaped = jsonEncode(raw);
    expect(
        utf8.encode(escaped).length, 6 * GeneratedLimits.submissionBytes + 2);
    final frame = IpcEnvelopeCodec.encodeRequest('r', escaped);
    expect(IpcEnvelopeDecoder().consume(frame).envelope!.payload, escaped);
    for (final count in [24000, 32768]) {
      final text = 'x' * count;
      final response = IpcEnvelopeCodec.encodeResponse('r', text);
      expect(IpcEnvelopeDecoder().consume(response).envelope!.payload, text);
    }
    // Pure representation budget proof, not a claim this text is a STAGE DTO.
  });

  test('partial allocation remains one bounded body, close clears it', () {
    final decoder = IpcEnvelopeDecoder();
    final prefix = rawFrame(length: IpcEnvelopeLimits.requestBytes, body: []);
    expect(decoder.consume(prefix).envelope, isNull);
    expect(decoder.allocatedPayloadBytes, IpcEnvelopeLimits.requestBytes);
    expect(decoder.retainedByteCapacity, IpcEnvelopeLimits.frameBytes);
    decoder.close();
    decoder.close();
    cleared(decoder);
    expect(() => decoder.finish(), failure(IpcProtocolFailure.closed));
    expect(() => decoder.consume(Uint8List(0)),
        failure(IpcProtocolFailure.closed));
    final replacement = IpcEnvelopeDecoder();
    expect(replacement.consume(rawFrame()).envelope!.payload, 'x');
  });

  test('encoding failure is isolated from a partially received decoder', () {
    final decoder = IpcEnvelopeDecoder();
    final frame = IpcEnvelopeCodec.encodeRequest('r', 'payload');
    decoder.consume(Uint8List.sublistView(frame, 0, 18));
    final buffered = decoder.bufferedBytes;
    expect(() => IpcEnvelopeCodec.encodeRequest('bad/id', 'private-content'),
        failure(IpcProtocolFailure.invalidId));
    expect(decoder.bufferedBytes, buffered);
    expect(decoder.consume(Uint8List.sublistView(frame, 18)).envelope!.payload,
        'payload');
  });

  test('empty chunks, end offset, invalid offsets and clean EOF are defined',
      () {
    final decoder = IpcEnvelopeDecoder();
    expect(decoder.consume(Uint8List(0)).consumed, 0);
    expect(decoder.consume(rawFrame(), offset: rawFrame().length).envelope,
        isNull);
    decoder.finish();
    cleared(decoder);
    for (final offset in [-1, 100]) {
      final next = IpcEnvelopeDecoder();
      expect(() => next.consume(rawFrame(), offset: offset),
          failure(IpcProtocolFailure.invalidFrame));
      cleared(next);
    }
  });

  test('forged authority remains opaque text, correlation is not a key factory',
      () {
    final claims = jsonEncode({
      'clientProfileId': 'fake-profile',
      'sessionId': 'fake-session',
      'recipient': 'fake-recipient',
      'scope': '*',
      'grant': ['COMMIT'],
      'trusted': true,
      'submissionKey': 'different-from-request-id',
    });
    final decoder = IpcEnvelopeDecoder();
    final result = decoder
        .consume(IpcEnvelopeCodec.encodeRequest('correlation', claims))
        .envelope!;
    expect(result, isA<UntrustedIpcEnvelope>());
    expect(result.payload, claims);
    expect(result.requestId, 'correlation');
    expect(result.toString(), 'UntrustedIpcEnvelope(request)');
    expect(result.toString(), isNot(contains('fake-profile')));
  });

  test('safe exception output contains only fixed classification', () {
    try {
      IpcEnvelopeCodec.encodeRequest('private/path', 'private-token-body');
      fail('expected safe rejection');
    } on IpcProtocolException catch (error) {
      expect(error.toString(), 'IpcProtocolException(invalidId)');
      expect(error.failure, IpcProtocolFailure.invalidId);
    }
  });

  test('seeded arbitrary bytes cannot crash or retain unlimited data', () {
    final random = Random(91831);
    for (var sample = 0; sample < 2000; sample++) {
      final bytes = Uint8List.fromList(
          List.generate(random.nextInt(193), (_) => random.nextInt(256)));
      final decoder = IpcEnvelopeDecoder();
      try {
        consumeAll(decoder, bytes);
        decoder.finish();
      } on IpcProtocolException catch (error) {
        expect(IpcProtocolFailure.values, contains(error.failure));
      }
      cleared(decoder);
      expect(decoder.peakPayloadBytes, 0);
    }
  });

  test('seeded valid envelopes roundtrip over arbitrary chunking/coalescing',
      () {
    final random = Random(997);
    const scalars = [
      0,
      10,
      34,
      92,
      65,
      0x7ff,
      0x800,
      0x4e2d,
      0xfeff,
      0x10000,
      0x1f642,
      0x10ffff
    ];
    for (var sample = 0; sample < 200; sample++) {
      final payloads = List.generate(
          4,
          (_) => String.fromCharCodes(List.generate(1 + random.nextInt(80),
              (_) => scalars[random.nextInt(scalars.length)])));
      final frames = List.generate(
          4,
          (i) => i.isEven
              ? IpcEnvelopeCodec.encodeRequest('id$i', payloads[i])
              : IpcEnvelopeCodec.encodeResponse('id$i', payloads[i]));
      for (var i = 0; i < frames.length; i++) {
        expect(Uint8List.sublistView(frames[i], 19), utf8.encode(payloads[i]));
      }
      final bytes = Uint8List.fromList(frames.expand((f) => f).toList());
      final decoder = IpcEnvelopeDecoder();
      final output = <UntrustedIpcEnvelope>[];
      var offset = 0;
      while (offset < bytes.length) {
        final end = min(bytes.length, offset + 1 + random.nextInt(31));
        output.addAll(
            consumeAll(decoder, Uint8List.sublistView(bytes, offset, end)));
        offset = end;
        expect(decoder.retainedByteCapacity,
            lessThanOrEqualTo(IpcEnvelopeLimits.frameBytes));
      }
      decoder.finish();
      expect(output.map((e) => e.payload), payloads);
      expect(output.map((e) => e.kind), [
        IpcMessageKind.request,
        IpcMessageKind.response,
        IpcMessageKind.request,
        IpcMessageKind.response
      ]);
      for (var i = 0; i < frames.length; i++) {
        expect(IpcEnvelopeCodec.encode(output[i]), frames[i]);
      }
    }
  });

  test(
      'structured header mutations and bounded bodies fail safely or roundtrip',
      () {
    final random = Random(34517);
    final original = IpcEnvelopeCodec.encodeRequest('safe', '中🙂payload');
    for (var sample = 0; sample < 1200; sample++) {
      final bytes = Uint8List.fromList(original);
      bytes[random.nextInt(bytes.length)] = random.nextInt(256);
      final decoder = IpcEnvelopeDecoder();
      try {
        final results = consumeAll(decoder, bytes);
        decoder.finish();
        for (final result in results) {
          final encoded = IpcEnvelopeCodec.encode(result);
          final check = IpcEnvelopeDecoder();
          expect(check.consume(encoded).envelope!.payload, result.payload);
          check.finish();
        }
      } on IpcProtocolException catch (error) {
        expect(IpcProtocolFailure.values, contains(error.failure));
      }
      cleared(decoder);
      expect(decoder.peakPayloadBytes,
          lessThanOrEqualTo(IpcEnvelopeLimits.requestBytes));
    }
  });

  test('infrastructure isolation and no production listener/authority wiring',
      () {
    final source =
        File('lib/data/external/ipc_envelope_codec.dart').readAsStringSync();
    final imports = RegExp(r'''import\s+['"]([^'"]+)['"]''')
        .allMatches(source)
        .map((m) => m.group(1)!)
        .toList();
    expect(imports, ['dart:convert', 'dart:typed_data']);
    for (final forbidden in [
      'ExternalPrincipal',
      'ExternalSession',
      'LocalHostSessionEntry',
      'ExternalExecutionContext',
      'CapabilityExecutor',
      'ExternalCapabilityGateway',
      'ServerSocket',
      'HttpServer',
      'Socket.connect',
      'DatabaseHelper',
      'jsonDecode',
      'dart:io',
      'dart:ffi',
      'mcp_dart'
    ]) {
      expect(source, isNot(contains(forbidden)), reason: forbidden);
    }
    final consumers = <String>[];
    for (final file in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) =>
            f.path.endsWith('.dart') &&
            !f.path.endsWith('ipc_envelope_codec.dart'))) {
      if (file.readAsStringSync().contains('ipc_envelope_codec.dart')) {
        consumers.add(file.path.replaceAll('\\', '/'));
      }
    }
    // P10 is the only authorized offline consumer; production remains unwired.
    expect(consumers, ['lib/data/external/ipc_command_projection.dart']);
    for (final consumer in consumers) {
      final body = File(consumer).readAsStringSync();
      for (final forbidden in [
        'dart:io',
        'dart:ffi',
        'ServerSocket',
        'HttpServer',
        'Socket.connect',
        'DatabaseHelper',
        'mcp_dart'
      ]) {
        expect(body.contains(forbidden), isFalse,
            reason: '$consumer: $forbidden');
      }
    }
  });
}
