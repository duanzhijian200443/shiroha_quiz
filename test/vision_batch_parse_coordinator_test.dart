import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/vision_batch_parse_coordinator.dart';

void main() {
  group('VisionBatchParseCoordinator Tests', () {
    test(
        'Empty imagePaths returns empty list with warning and status diagnostics',
        () async {
      const coordinator = VisionBatchParseCoordinator();
      final res = await coordinator.parse(
        imagePaths: [],
        parseBatch: (paths) async => [],
      );

      expect(res.questions, isEmpty);
      expect(res.warnings.length, 1);
      expect(res.warnings[0].contains('未接收到任何图片资产'), true);
      expect(res.diagnostics['status'], 'empty_input');
    });

    test('maxConcurrency < 1 is normalized to 1', () async {
      const coordinator = VisionBatchParseCoordinator();
      final List<List<String>> scheduledBatches = [];

      final res = await coordinator.parse(
        imagePaths: ['p1.png', 'p2.png'],
        pagesPerBatch: 1,
        maxConcurrency: 0,
        parseBatch: (paths) async {
          scheduledBatches.add(paths);
          return [
            {'content': 'Question from ${paths.first}'}
          ];
        },
      );

      expect(res.questions.length, 2);
      expect(scheduledBatches.length, 2);
      expect(res.diagnostics['concurrencyHistory']['finalConcurrency'], 1);
    });

    test(
        'Groups into non-overlapping batches and maintains order regardless of completion sequence',
        () async {
      const coordinator = VisionBatchParseCoordinator();
      final List<List<String>> scheduled = [];
      final List<int> completedIdx = [];

      final res = await coordinator.parse(
        imagePaths: ['1.jpg', '2.jpg', '3.jpg', '4.jpg', '5.jpg'],
        pagesPerBatch: 2,
        maxConcurrency: 3,
        parseBatch: (paths) async {
          scheduled.add(paths);
          final first = paths.first;
          // Artificially make second batch complete slower to simulate out-of-order execution
          if (first == '3.jpg') {
            await Future.delayed(const Duration(milliseconds: 50));
            completedIdx.add(1);
            return [
              {'q': 'B2_Q1'}
            ];
          } else if (first == '1.jpg') {
            completedIdx.add(0);
            return [
              {'q': 'B1_Q1'}
            ];
          } else {
            completedIdx.add(2);
            return [
              {'q': 'B3_Q1'}
            ];
          }
        },
      );

      // Verify batch sizes: B1=[1, 2], B2=[3, 4], B3=[5]
      expect(scheduled.length, 3);
      expect(scheduled[0], ['1.jpg', '2.jpg']);
      expect(scheduled[1], ['3.jpg', '4.jpg']);
      expect(scheduled[2], ['5.jpg']);

      // Completion was out of order
      expect(completedIdx, [0, 2, 1]);

      // Final questions must be ordered by batch index: B1, B2, B3
      expect(res.questions.length, 3);
      expect(res.questions[0]['q'], 'B1_Q1');
      expect(res.questions[1]['q'], 'B2_Q1');
      expect(res.questions[2]['q'], 'B3_Q1');
    });

    test(
        'Recovers from transient failure with backoff and concurrency reduction',
        () async {
      const coordinator = VisionBatchParseCoordinator();
      int callCount = 0;
      final List<Duration> delays = [];

      final res = await coordinator.parse(
        imagePaths: ['1.jpg', '2.jpg'],
        pagesPerBatch: 1,
        maxConcurrency: 2,
        delayOverride: (duration) async {
          delays.add(duration);
        },
        parseBatch: (paths) async {
          callCount++;
          if (paths.first == '1.jpg' && callCount == 1) {
            // Throw transient error first time
            throw Exception('HTTP 429 Too Many Requests');
          }
          return [
            {'q': 'Q_${paths.first}'}
          ];
        },
      );

      // It should succeed on retry
      expect(res.questions.length, 2);
      expect(res.questions[0]['q'], 'Q_1.jpg');
      expect(res.questions[1]['q'], 'Q_2.jpg');

      // 1st call: batch0 (throws 429)
      // 2nd call: batch0 (retry success)
      // 3rd call: batch1 (success)
      expect(callCount, 3);

      // Concurrency was reduced by 1
      expect(res.diagnostics['concurrencyHistory']['finalConcurrency'], 1);
      // Wait delay should be 3s
      expect(delays.length, 1);
      expect(delays.first.inSeconds, 3);
    });

    test(
        'Skips non-transient failure batch and continues parsing other batches',
        () async {
      const coordinator = VisionBatchParseCoordinator();

      final res = await coordinator.parse(
        imagePaths: ['good.jpg', 'bad.jpg', 'ok.jpg'],
        pagesPerBatch: 1,
        maxConcurrency: 1,
        parseBatch: (paths) async {
          if (paths.first == 'bad.jpg') {
            throw Exception('Non-transient error: Invalid Image Format');
          }
          return [
            {'q': 'Q_${paths.first}'}
          ];
        },
      );

      // Only 'good.jpg' and 'ok.jpg' should be parsed
      expect(res.questions.length, 2);
      expect(res.questions[0]['q'], 'Q_good.jpg');
      expect(res.questions[1]['q'], 'Q_ok.jpg');

      expect(res.failedBatchCount, 1);
      expect(res.warnings.length, 1);
      expect(res.warnings[0].contains('视觉解析失败'), true);
      expect(res.diagnostics['errors'].length, 1);
      expect(
          res.diagnostics['errors'][0].contains('Invalid Image Format'), true);
    });

    test('Transient error triggers onBatchRetry but not onBatchFailed',
        () async {
      const coordinator = VisionBatchParseCoordinator();
      int callCount = 0;
      int failedCount = 0;
      int retryCount = 0;

      final res = await coordinator.parse(
        imagePaths: ['1.jpg'],
        pagesPerBatch: 1,
        maxConcurrency: 1,
        delayOverride: (duration) async {},
        parseBatch: (paths) async {
          callCount++;
          if (callCount == 1) {
            throw Exception('Timeout Exception');
          }
          return [
            {'q': 'Success'}
          ];
        },
        onBatchFailed: (batchIdx, error) {
          failedCount++;
        },
        onBatchRetry: (batchIdx, error) {
          retryCount++;
        },
      );

      expect(callCount, 2);
      expect(failedCount, 0); // Should not trigger failed on transient error
      expect(retryCount, 1); // Should trigger retry
      expect(res.questions.length, 1);
    });
  });
}
