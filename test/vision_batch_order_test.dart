import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Vision Batch Concurrency Ordered Merge Test', () {
    test('Should flatten results by batch index even if completed out of order',
        () async {
      // 模拟 3 个批次的图片数据
      final batches = [
        ['img_0_p1.jpg', 'img_0_p2.jpg'], // batch 0
        ['img_1_p1.jpg', 'img_1_p2.jpg'], // batch 1
        ['img_2_p1.jpg', 'img_2_p2.jpg'], // batch 2
      ];

      // 有序结果池
      final List<List<Map<String, dynamic>>?> orderedResults =
          List.filled(batches.length, null);

      // 待处理队列
      List<int> pendingIndices = List.generate(batches.length, (i) => i);

      int maxConcurrency = 2; // 允许并发 2 个
      final List<Future<void>> workers = [];

      // 模拟的异步解析服务，刻意让 batch 1 最慢，batch 2 最快，batch 0 居中
      Future<List<Map<String, dynamic>>> mockParse(int batchIndex) async {
        if (batchIndex == 0) {
          await Future.delayed(const Duration(milliseconds: 50));
        } else if (batchIndex == 1) {
          await Future.delayed(const Duration(milliseconds: 100));
        } else if (batchIndex == 2) {
          await Future.delayed(const Duration(milliseconds: 10));
        }
        return [
          {'q_num': 'Q_${batchIndex}_1'},
          {'q_num': 'Q_${batchIndex}_2'}
        ];
      }

      final workerCount = maxConcurrency.clamp(1, pendingIndices.length);
      for (int w = 0; w < workerCount; w++) {
        workers.add(() async {
          while (pendingIndices.isNotEmpty) {
            final batchIdx = pendingIndices.removeAt(0);
            final res = await mockParse(batchIdx);
            orderedResults[batchIdx] = res;
          }
        }());
      }

      await Future.wait(workers);

      // 验证各个批次是否都被填满
      expect(orderedResults.contains(null), isFalse);

      // 按 batchIndex 顺序展平
      List<Map<String, dynamic>> singleFileQuestions = [];
      for (final batchResult in orderedResults) {
        if (batchResult != null) {
          singleFileQuestions.addAll(batchResult);
        }
      }

      // 验证展平后的顺序必须是 Q_0_1, Q_0_2, Q_1_1, Q_1_2, Q_2_1, Q_2_2
      expect(singleFileQuestions.length, 6);
      expect(singleFileQuestions[0]['q_num'], 'Q_0_1');
      expect(singleFileQuestions[1]['q_num'], 'Q_0_2');
      expect(singleFileQuestions[2]['q_num'], 'Q_1_1');
      expect(singleFileQuestions[3]['q_num'], 'Q_1_2');
      expect(singleFileQuestions[4]['q_num'], 'Q_2_1');
      expect(singleFileQuestions[5]['q_num'], 'Q_2_2');
    });
  });
}
