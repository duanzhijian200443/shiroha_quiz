import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/parse_batch_runner.dart';

void main() {
  group('ParseBatchRunner', () {
    test('keeps parsed questions in original chunk order', () async {
      final runner = ParseBatchRunner(
        maxConcurrent: 2,
        successPause: Duration.zero,
        retryDelayFor: (_, __) => Duration.zero,
      );

      final result = await runner.run(
        chunks: ['slow', 'fast'],
        parseChunk: (chunk) async {
          if (chunk == 'slow') {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          return [
            {'content': chunk},
          ];
        },
      );

      expect(result.failedCount, 0);
      expect(result.questions.map((q) => q['content']), ['slow', 'fast']);
    });

    test('retries failures and reports permanently failed chunks', () async {
      final runner = ParseBatchRunner(
        maxConcurrent: 1,
        maxRetries: 2,
        successPause: Duration.zero,
        retryDelayFor: (_, __) => Duration.zero,
      );
      final failedChunks = <String>[];
      var attempts = 0;

      final result = await runner.run(
        chunks: ['bad'],
        parseChunk: (_) async {
          attempts++;
          throw Exception('timeout');
        },
        onChunkFailed: failedChunks.add,
      );

      expect(attempts, 2);
      expect(result.failedCount, 1);
      expect(result.questions, isEmpty);
      expect(failedChunks, ['bad']);
    });
  });
}
