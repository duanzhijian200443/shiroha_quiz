import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/training/training_allocation.dart';
import 'package:shiroha_quiz/domain/training/training_content_member.dart';

List<TrainingContentMember> members(List<int> weights) => [
      for (var i = 0; i < weights.length; i++)
        TrainingContentMember(
            bankName: 'b$i', weightPercent: weights[i], position: i),
    ];

List<int> takes(List<int> weights, List<int> available, int limit) =>
    TrainingAllocation.newQuestionTakes(
        questionLimit: limit,
        members: members(weights),
        availableNewCounts: {
          for (var i = 0; i < weights.length; i++)
            if (weights[i] > 0) 'b$i': available[i],
        }).values.toList();

void main() {
  test('ideal quotas retain remainder and position/bank tie-break', () {
    expect(takes([100], [1000], 100), [100]);
    expect(takes([50, 50], [10, 10], 1), [1, 0]);
    expect(takes([34, 33, 33], [100, 100, 100], 5), [2, 2, 1]);
    final tied = [
      TrainingContentMember(bankName: 'B', weightPercent: 50, position: 0),
      TrainingContentMember(bankName: 'A', weightPercent: 50, position: 0),
    ];
    expect(
        TrainingAllocation.newQuestionTakes(
            questionLimit: 1,
            members: tied,
            availableNewCounts: {'A': 1, 'B': 1}),
        {'B': 0, 'A': 1});
  });
  test('shortages cap capacity and refill through several rounds', () {
    expect(takes([50, 50], [1, 100], 10), [1, 9]);
    expect(takes([80, 15, 5], [1, 2, 100], 20), [1, 2, 17]);
    expect(takes([80, 15, 5], [1, 2, 3], 100), [1, 2, 3]);
    expect(takes([50, 50], [0, 0], 1), [0, 0]);
    // Refill uses original relative weights, not equal shares.
    expect(takes([50, 30, 20], [0, 100, 100], 10), [0, 6, 4]);
  });
  test('zero weights need no count and never refill even with spare capacity',
      () {
    expect(takes([100, 0], [2, 1000], 100), [2, 0]);
    expect(takes([50, 0, 50], [0, 1000, 10], 100), [0, 0, 10]);
    expect(takes([100, 0], [0, 1000], 1), [0, 0]);
  });
  test('bounded deterministic distributions exhaust exactly available capacity',
      () {
    final rng = Random(42);
    for (var trial = 0; trial < 500; trial++) {
      final a = rng.nextInt(101);
      final b = rng.nextInt(101 - a);
      final weights = [a, b, 100 - a - b];
      final available = List.generate(3, (_) => rng.nextInt(120));
      final limit = rng.nextInt(100) + 1;
      final result = takes(weights, available, limit);
      final total = [
        for (var i = 0; i < 3; i++)
          if (weights[i] > 0) available[i]
      ].fold<int>(0, (sum, n) => sum + n);
      expect(result.fold<int>(0, (sum, n) => sum + n), min(limit, total));
      for (var i = 0; i < 3; i++) {
        expect(result[i], inInclusiveRange(0, available[i]));
        if (weights[i] == 0) expect(result[i], 0);
      }
    }
  });
  test('missing or negative positive counts fail without mutating inputs', () {
    final selected = members([100, 0]);
    for (final counts in [
      <String, int>{},
      {'b0': -1}
    ]) {
      expect(
          () => TrainingAllocation.newQuestionTakes(
              questionLimit: 10, members: selected, availableNewCounts: counts),
          throwsFormatException);
    }
    final counts = {'b0': 1};
    final result = TrainingAllocation.newQuestionTakes(
        questionLimit: 10, members: selected, availableNewCounts: counts);
    expect(counts, {'b0': 1});
    expect(() => result['b0'] = 5, throwsUnsupportedError);
    expect(selected.map((m) => m.weightPercent), [100, 0]);
  });
}
