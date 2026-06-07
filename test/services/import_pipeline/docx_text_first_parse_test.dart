import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/answer_block_matcher.dart';
import 'package:shiroha_quiz/services/import_pipeline/text_question_region.dart';
import 'package:shiroha_quiz/services/import_pipeline/text_question_regionizer.dart';

void main() {
  group('AnswerBlockMatcher Tests', () {
    test('尾部标准答案区被正确识别提取', () {
      const rawText = '''
1. 第一题题目
2. 第二题题目

参考答案
1. A
2. B
''';
      final matcher = const AnswerBlockMatcher();
      final result = matcher.splitAnswerBlock(rawText);

      expect(result.answers.length, 2);
      expect(result.answers[1], 'A');
      expect(result.answers[2], 'B');
      expect(result.questionBodyText.contains('1. 第一题题目'), isTrue);
      expect(result.questionBodyText.contains('参考答案'), isFalse);
    });

    test('答案区在中间时，只要符合连续序列也能识别', () {
      const rawText = '''
前面的内容
解析
1. A
2. B
3. C
后面的无关内容
''';
      final matcher = const AnswerBlockMatcher();
      final result = matcher.splitAnswerBlock(rawText);

      expect(result.answers.length, 3);
      expect(result.answers[1], 'A');
      expect(result.answers[3], 'C');
      expect(result.questionBodyText.contains('前面的内容'), isTrue);
    });

    test('答案区内容 1.A / 2.B 被从原文本分离，不会被后续当成新题', () {
      const rawText = '''
第 1 题 测试
第 2 题 测试2
答案与解析
1. A
2. B
''';
      final matcher = const AnswerBlockMatcher();
      final split = matcher.splitAnswerBlock(rawText);
      final regionizer = const TextQuestionRegionizer();
      final regions = regionizer.split(split.questionBodyText, split.answers).regions;

      expect(regions.length, 2);
      expect(regions[0].number, 1);
      expect(regions[1].number, 2);
      // 答案已回填
      expect(regions[0].answerText, 'A');
      expect(regions[1].answerText, 'B');
    });
  });

  group('TextQuestionRegionizer Tests', () {
    test('内嵌编号 "1. TCP 是什么" 不应截断原有题干', () {
      const rawText = '''
1. 以下哪个关于网络协议的说法是正确的？
1. TCP 是什么？这是个内嵌的举例。
2. UDP 是什么？这也是个内嵌举例。
A. 选项A
B. 选项B
2. 下一题
''';
      final regionizer = const TextQuestionRegionizer();
      final regions = regionizer.split(rawText, {}).regions;
      
      // 第2个 "1. TCP..." 因为不满足单调性，会被当成正文或被 filter 过滤（或者因为其前面没有 A 选项之类的而融合）
      // 由于现有单调性过滤，如果 1 后面跟 1，会保留，但如果是伪题号可能抛弃。
      // 在本框架中，如果 "1. TCP..." 紧跟在 1. 之后，可能会判定为 number=1，但随后题号去重会保留最长文本。
      // 因此期望的题数是 2，或者是 1. 包含了这些正文。
      
      // 我们测试最终结果的题目数量。
      // 在当前去重逻辑中，同一个 number 出现多次，保留内容最长的。
      expect(regions.length, 2);
      expect(regions.any((r) => r.number == 1), isTrue);
      expect(regions.any((r) => r.number == 2), isTrue);
    });

    test('重复题号保留最长 region', () {
      const rawText = '''
1. 简短题干
1. 较长的题干，包含了更多的信息以及后续的选项内容。
2. 正常题干
''';
      final regionizer = const TextQuestionRegionizer();
      final regions = regionizer.split(rawText, {}).regions;
      
      expect(regions.length, 2);
      final q1 = regions.firstWhere((r) => r.number == 1);
      expect(q1.rawText.contains('较长的题干'), isTrue);
    });

    test('非选择题（没有 A/B 选项）不应自动进入 repairable', () {
      const rawText = '''
1. 证明题：请证明勾股定理。
2. 填空题：天空是___色的。
''';
      final regionizer = const TextQuestionRegionizer();
      final regions = regionizer.split(rawText, {}).regions;
      
      expect(regions.length, 2);
      expect(regions[0].kind, TextQuestionKind.subjective);
      expect(regions[0].health, RegionHealth.clean); // 主观题没有AB不修
      
      expect(regions[1].kind, TextQuestionKind.fillBlank);
      expect(regions[1].health, RegionHealth.clean); // 填空题也没有AB不修
    });

    test('选择题缺少 A/B/C/D 则进入 repairable', () {
      const rawText = '''
1. 以下说法正确的是：
选项内容不规范。
2. 这是一道单选题
A. 对
'''; // 第 2 题只有 A，没有 B
      final regionizer = const TextQuestionRegionizer();
      final regions = regionizer.split(rawText, {}).regions;
      
      expect(regions.length, 2);
      // 第1题由于没探测到A/B，且没有填空判断符，可能会被当成 subjective。
      // 如果被当成 subjective，它是 clean 的。
      // 第2题有 A 选项，会被判定为 choice。但缺少 B，所以会报错 repairable。
      expect(regions[1].kind, TextQuestionKind.choice);
      expect(regions[1].health, RegionHealth.repairable);
      expect(regions[1].diagnostics.contains('缺少 B 选项'), isTrue);
    });

    test('保留换行符', () {
      const rawText = '''
1. 第一题
这是第二行内容
这是第三行内容
''';
      final regionizer = const TextQuestionRegionizer();
      final regions = regionizer.split(rawText, {}).regions;
      
      expect(regions[0].rawText.contains('\n这是第二行内容'), isTrue);
      expect(regions[0].rawText.contains('\n这是第三行内容'), isTrue);
    });
  });
}
