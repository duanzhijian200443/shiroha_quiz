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

    for (final fault in ['missing', 'foreign', 'duplicate']) {
      test('$fault output cannot complete the script', () async {
        expect((await post([])).status, 200);
        final output = {
          'type': 'function_call_output',
          'call_id': fault == 'foreign' ? 'foreign-call' : 'probe-call-0',
          'output': '{"data":{}}',
        };
        final response = await post([
          if (fault != 'missing') output,
          if (fault == 'duplicate') output,
        ]);
        expect(response.status, 500);
        expect(response.body, isNot(contains('Offline probe complete.')));
        expect(model.finished, isFalse);
        expect(model.outputs, isEmpty);
        expect(model.failures, ['missing_original_output']);
      });
    }
  });
}
