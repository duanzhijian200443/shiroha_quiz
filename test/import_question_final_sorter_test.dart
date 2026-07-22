import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_final_sorter.dart';

/// Helper to build a question map with _import_review risk hints.
Map<String, dynamic> _q({
  required int index,
  dynamic type,
  String? qNum,
  List<String>? riskHints,
  List<int>? originalIndices,
}) {
  final meta = <String, dynamic>{
    'source': 'vision',
    'sources': ['vision'],
    'fragmentKinds': ['fullQuestion'],
    'originalIndices': originalIndices ?? [index],
    'riskHints': riskHints ?? [],
  };
  return {
    'q_num': qNum,
    'type': type,
    'content': 'question $index',
    '_import_review': meta,
  };
}

void main() {
  const sorter = ImportQuestionFinalSorter();

  group('ImportQuestionFinalSorter type ordering', () {
    test('orders by type rank: choice, fill, essay, judgment, unknown', () {
      final input = [
        _q(index: 0, type: 3, qNum: '3'),
        _q(index: 1, type: 0, qNum: '1'),
        _q(index: 2, type: 2, qNum: '2'),
        _q(index: 3, type: 1, qNum: '4'),
        _q(index: 4, type: 4, qNum: '5'),
        _q(index: 5, type: null, qNum: '6'),
      ];

      final result = sorter.sort(input);

      final types = result.questions.map((q) => q['type']).toList();
      expect(types, [0, 1, 2, 3, 4, null]);
      expect(result.diagnostics['total'], 6);
      expect(result.diagnostics['typeBuckets'], {
        'choice': 2,
        'fill': 1,
        'essay': 1,
        'judgment': 1,
        'unknown': 1,
      });
    });

    test('sorts by reliable q_num within same type', () {
      final input = [
        _q(index: 0, type: 0, qNum: '10'),
        _q(index: 1, type: 0, qNum: '2'),
        _q(index: 2, type: 0, qNum: '1'),
      ];

      final result = sorter.sort(input);

      final nums = result.questions.map((q) => q['q_num']).toList();
      expect(nums, ['1', '2', '10']);
    });

    test('falls back to source order when q_num is unreliable', () {
      // Q index=0 has q_num=1 but q_num_drift → unreliable
      // Q index=1 has q_num=10, reliable
      final input = [
        _q(index: 0, type: 3, qNum: '1', riskHints: ['q_num_drift']),
        _q(index: 1, type: 3, qNum: '10'),
      ];

      final result = sorter.sort(input);

      // index=0 has unreliable q_num, index=1 has reliable q_num=10
      // source order: index=0 → 0, index=1 → 1
      // With hasReliableQNum mismatch, q_num not compared → source order wins
      // index=0 (source=0) < index=1 (source=1)
      expect(result.questions[0]['content'], 'question 0');
      expect(result.questions[1]['content'], 'question 1');
    });

    test('two unreliable q_nums degrade to source order', () {
      final input = [
        _q(
          index: 2,
          type: 0,
          qNum: '1',
          riskHints: ['duplicate_q_num'],
          originalIndices: [5],
        ),
        _q(
          index: 3,
          type: 0,
          qNum: '2',
          riskHints: ['q_num_drift'],
          originalIndices: [2],
        ),
      ];

      final result = sorter.sort(input);

      // Both unreliable → source order from originalIndices: 2 < 5
      expect(result.questions[0]['content'], 'question 3');
      expect(result.questions[1]['content'], 'question 2');
    });
  });

  group('ImportQuestionFinalSorter source order', () {
    test('reads _import_review.originalIndices as source order', () {
      final input = [
        _q(
          index: 0,
          type: 3,
          qNum: '1',
          riskHints: ['q_num_drift'],
          originalIndices: [8],
        ),
        _q(
          index: 1,
          type: 3,
          qNum: '2',
          riskHints: ['q_num_drift'],
          originalIndices: [2],
        ),
      ];

      final result = sorter.sort(input);

      expect(result.questions[0]['content'], 'question 1');
      expect(result.questions[1]['content'], 'question 0');
    });

    test('uses min of originalIndices for fused fragments', () {
      final input = [
        _q(
          index: 0,
          type: 3,
          qNum: '1',
          riskHints: ['q_num_drift'],
          originalIndices: [3, 7, 1],
        ),
        _q(
          index: 1,
          type: 3,
          qNum: '2',
          riskHints: ['q_num_drift'],
          originalIndices: [0, 5],
        ),
      ];

      final result = sorter.sort(input);

      // min(0,5) = 0 < min(3,7,1) = 1 → index=1 comes first
      expect(result.questions[0]['content'], 'question 1');
      expect(result.questions[1]['content'], 'question 0');
    });
  });

  group('ImportQuestionFinalSorter robustness', () {
    test('does not throw on null _import_review', () {
      final input = [
        {'q_num': '1', 'type': 0, 'content': 'has meta', '_import_review': {}},
        {'q_num': '2', 'type': 0, 'content': 'null meta'},
        {
          'q_num': '3',
          'type': 0,
          'content': 'string meta',
          '_import_review': 'bad'
        },
      ];

      final result = sorter.sort(input);
      expect(result.questions, hasLength(3));
    });

    test('does not throw on bad originalIndices', () {
      final metaWithIndices = (List<dynamic> indices) => {
            'source': 'vision',
            'sources': ['vision'],
            'fragmentKinds': ['fullQuestion'],
            'originalIndices': indices,
            'riskHints': <String>[],
          };

      final input = [
        {
          'q_num': '1',
          'type': 0,
          'content': 'a',
          '_import_review': metaWithIndices(['bad']),
        },
        {
          'q_num': '2',
          'type': 0,
          'content': 'b',
          '_import_review': metaWithIndices([null]),
        },
        {
          'q_num': '3',
          'type': 0,
          'content': 'c',
          '_import_review': metaWithIndices([2.0]),
        },
      ];

      final result = sorter.sort(input);
      expect(result.questions, hasLength(3));
    });

    test('does not modify question content', () {
      final q = _q(
        index: 0,
        type: 0,
        qNum: 'hello 123',
        riskHints: ['q_num_drift', 'orphan_fragment'],
      );
      q['standard_answer'] = 'B';
      q['options'] = ['A', 'B'];
      q['explanation'] = 'explains';

      final originalContent = q['content'];
      final originalAnswer = q['standard_answer'];
      final originalOptions = q['options'];
      final originalExplanation = q['explanation'];
      final originalHints =
          List<String>.from((q['_import_review'] as Map)['riskHints']);

      final items = [q];
      // Add another question to force a sort
      items.add(_q(index: 1, type: 1, qNum: '99'));
      sorter.sort(items);

      expect(q['content'], originalContent);
      expect(q['standard_answer'], originalAnswer);
      expect(q['options'], originalOptions);
      expect(q['explanation'], originalExplanation);
      expect(
        (q['_import_review'] as Map)['riskHints'],
        originalHints,
      );
    });

    test('handles string, double, and num type values', () {
      final input = [
        _q(index: 0, type: '0', qNum: '1'),
        _q(index: 1, type: 2.0, qNum: '2'),
        _q(index: 2, type: 3, qNum: '3'),
      ];

      final result = sorter.sort(input);
      final types = result.questions.map((q) => q['type']).toList();
      // '0' → rank 0, 2.0 → rank 1, 3 → rank 2
      expect(types[0], '0');
      expect(types[1], 2.0);
      expect(types[2], 3);
    });

    test('negative originalIndices are treated as missing (q_num unreliable)',
        () {
      // A has originalIndices [-1] → falls back to list index 1
      // B has originalIndices [0]  → sourceOrder = 0
      // Both q_num unreliable → sourceOrder decides: B (0) < A (1)
      final input = [
        _q(
          index: 0,
          type: 0,
          qNum: '1',
          riskHints: ['q_num_drift'],
          originalIndices: [0],
        ),
        _q(
          index: 1,
          type: 0,
          qNum: '2',
          riskHints: ['q_num_drift'],
          originalIndices: [-1],
        ),
      ];

      final result = sorter.sort(input);
      expect(result.questions[0]['content'], 'question 0');
      expect(result.questions[1]['content'], 'question 1');
    });

    test('strictly deterministic — no random jitter', () {
      final input = List.generate(20, (i) => _q(index: i, type: 3, qNum: '1'));
      final r1 = sorter.sort(input);
      final r2 = sorter.sort(input);

      for (var i = 0; i < r1.questions.length; i++) {
        expect(
          r1.questions[i]['content'],
          r2.questions[i]['content'],
          reason: 'position $i must be deterministic',
        );
      }
    });
  });

  group('ImportQuestionFinalSorter diagnostics', () {
    test('movedCount reflects reordered items', () {
      final input = [
        _q(index: 0, type: 3, qNum: '3'),
        _q(index: 1, type: 0, qNum: '1'),
      ];

      final result = sorter.sort(input);
      expect(result.diagnostics['movedCount'], greaterThan(0));
    });

    test('empty input returns zero diagnostics', () {
      final result = sorter.sort([]);
      expect(result.questions, isEmpty);
      expect(result.diagnostics['total'], 0);
      expect(result.diagnostics['movedCount'], 0);
    });

    test('single item returns movedCount 0', () {
      final result = sorter.sort([_q(index: 0, type: 0, qNum: '1')]);
      expect(result.diagnostics['total'], 1);
      expect(result.diagnostics['movedCount'], 0);
    });
  });
}
