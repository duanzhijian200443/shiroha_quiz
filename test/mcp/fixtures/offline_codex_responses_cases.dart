import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'offline_codex_responses.dart';

final class _LoopbackHttpOverrides extends HttpOverrides {}

void offlineCodexResponsesCases() {
  group('offline Responses evidence guard', () {
    late OfflineCodexResponses model;
    late HttpClient http;
    setUp(() async {
      model = OfflineCodexResponses([
        ScriptedMcpCall('open_generation_context', (_) => {}),
      ]);
      await model.start();
      // Widget binding supplies a fixed-400 mock. This bounded socket test must
      // reach its own loopback server; leave the enclosing override unchanged.
      http = HttpOverrides.runWithHttpOverrides(
          () => HttpClient()..findProxy = (_) => 'DIRECT',
          _LoopbackHttpOverrides());
    });
    tearDown(() async {
      http.close(force: true);
      await model.close();
    });
    Future<({int status, String body})> post(List<Object?> input) async {
      final request = await http.postUrl(Uri.parse('${model.base}/responses'));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({
        'stream': true,
        'input': input,
        'tools': [
          {
            'type': 'namespace',
            'name': 'mcp__shiroha_vnext',
            'tools': [
              {'type': 'function', 'name': 'open_generation_context'}
            ],
          }
        ],
      }));
      final response = await request.close();
      return (
        status: response.statusCode,
        body: await utf8.decoder.bind(response).join()
      );
    }

    test('final model message requires the exact original call output',
        () async {
      final first = await post([]);
      expect(first.status, 200);
      expect(first.body, contains('"type":"function_call"'));
      expect(first.body, isNot(contains('Offline probe complete.')));
      const returned = {
        'data': {'sentinel': 'actual-returned-data'}
      };
      final second = await post([
        {
          'type': 'function_call_output',
          'call_id': 'probe-call-0',
          'output':
              'Wall time: 0.0123 seconds\nOutput:\n${jsonEncode(returned)}',
        }
      ]);
      expect(second.status, 200);
      expect(second.body, contains('Offline probe complete.'));
      expect(model.outputs.single, returned);
      expect(model.failures, isEmpty);
      expect(model.finished, isTrue);
    });

    Map<String, Object?> output(String id) => {
          'type': 'function_call_output',
          'call_id': id,
          'output': jsonEncode({
            'data': {'sentinel': id}
          }),
        };

    test(
        'both MCP error spellings and malformed flags reject before projection',
        () {
      for (final key in ['isError', 'is_error']) {
        for (final flag in [true, null, 0, 'false']) {
          expect(
              () => OfflineCodexResponses.decodeOutput({
                    key: flag,
                    'structuredContent': {
                      'data': {'ok': true}
                    },
                  }),
              throwsStateError);
        }
      }
      expect(
          () => OfflineCodexResponses.decodeOutput({
                'error': 'synthetic',
                'structuredContent': {
                  'data': {'ok': true}
                },
              }),
          throwsStateError);
    });

    test(
        'total limit counts unexpected requests and first failure stops service',
        () async {
      final request =
          await http.getUrl(Uri.parse('${model.base}/not-responses'));
      final response = await request.close();
      await response.drain<void>();
      expect(response.statusCode, 500);
      expect(model.totalRequests, 1);
      expect(model.requests, 0);
      expect(model.failures, ['unexpected_request_or_auth']);
      expect(model.finished, isFalse);
      await model.close();
      expect(model.failures, hasLength(1));
    });

    test('a third POST cannot extend a completed one-call script', () async {
      expect((await post([])).status, 200);
      expect((await post([output('probe-call-0')])).status, 200);
      expect((await post([output('probe-call-0')])).status, 500);
      expect(model.totalRequests, 3);
      expect(model.requests, 2);
      expect(model.failures, ['total_request_limit']);
    });

    for (final fault in ['none', 'nonce', 'error', 'wrapper-error', 'extra']) {
      test('strict synthetic output checks $fault before sending final',
          () async {
        await model.close();
        model = OfflineCodexResponses([
          ScriptedMcpCall('open_generation_context', (_) => {}),
        ],
            validateOutput: (_, value) =>
                value.length == 1 &&
                value['data'] is Map &&
                (value['data'] as Map).length == 2 &&
                value['data']['ok'] == true &&
                value['data']['nonce'] == 'public-nonce');
        await model.start();
        expect((await post([])).status, 200);
        final returned = <String, dynamic>{
          'data': {
            'ok': true,
            'nonce': fault == 'nonce' ? 'foreign-nonce' : 'public-nonce',
          }
        };
        if (fault == 'error') returned['error'] = 'synthetic';
        if (fault == 'extra') returned['extra'] = 'SENTINEL';
        final response = await post([
          {
            'type': 'function_call_output',
            'call_id': 'probe-call-0',
            'output': jsonEncode(fault == 'wrapper-error'
                ? {'isError': true, 'structuredContent': returned}
                : returned),
          }
        ]);
        expect(response.status, fault == 'none' ? 200 : 500);
        expect(model.finished, fault == 'none');
        expect(
            response.body.contains('Offline probe complete.'), fault == 'none');
        expect(response.body, isNot(contains('SENTINEL')));
        expect(model.outputs, hasLength(fault == 'none' ? 1 : 0));
      });
    }

    void expectRejected(({int status, String body}) response,
        {int acceptedOutputs = 0, required String category}) {
      expect(response.status, 500);
      expect(response.body, isNot(contains('Offline probe complete.')));
      expect(response.body, isNot(contains('"type":"function_call"')));
      expect(model.finished, isFalse);
      expect(model.outputs, hasLength(acceptedOutputs));
      expect(model.failures, [category]);
    }

    for (final fault in [
      'missing',
      'foreign',
      'duplicate',
      'mixed foreign',
      'future'
    ]) {
      test('$fault output cannot complete the script', () async {
        expect((await post([])).status, 200);
        final response = await post([
          if (fault != 'missing' && fault != 'foreign') output('probe-call-0'),
          if (fault == 'foreign' || fault == 'mixed foreign')
            output('foreign-call'),
          if (fault == 'duplicate') output('probe-call-0'),
          if (fault == 'future') output('probe-call-1'),
        ]);
        expectRejected(response,
            category: fault == 'missing'
                ? 'missing_original_output'
                : 'invalid_output_set');
      });
    }

    for (final id in ['foreign-call', 'probe-call-0']) {
      test('initial output $id cannot issue a call', () async {
        expectRejected(await post([output(id)]),
            category: 'invalid_output_set');
        expect(model.issued, isEmpty);
      });
    }

    for (final history in [
      'retained',
      'omitted',
      'foreign',
      'duplicate',
      'missing latest'
    ]) {
      test('$history prior output is checked with the latest output', () async {
        // Two issued calls distinguish legitimate retained history from an
        // unknown ID, a duplicate old ID, or history without the latest result.
        model.calls.add(ScriptedMcpCall('open_generation_context', (_) => {}));
        expect((await post([])).status, 200);
        expect((await post([output('probe-call-0')])).status, 200);
        expect(model.issued, hasLength(2));
        final response = await post([
          if (history != 'omitted') output('probe-call-0'),
          if (history != 'missing latest') output('probe-call-1'),
          if (history == 'foreign') output('foreign-call'),
          if (history == 'duplicate') output('probe-call-0'),
        ]);
        if (history == 'retained' || history == 'omitted') {
          expect(response.status, 200);
          expect(response.body, contains('Offline probe complete.'));
          expect(model.finished, isTrue);
          expect(model.failures, isEmpty);
          expect(model.outputs, [
            {
              'data': {'sentinel': 'probe-call-0'}
            },
            {
              'data': {'sentinel': 'probe-call-1'}
            },
          ]);
        } else {
          expectRejected(response,
              acceptedOutputs: 1,
              category: history == 'missing latest'
                  ? 'missing_original_output'
                  : 'invalid_output_set');
        }
      });
    }
  });
}
