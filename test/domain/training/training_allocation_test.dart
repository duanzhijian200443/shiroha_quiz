import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/training/training_allocation.dart';
import 'package:shiroha_quiz/domain/training/training_content_member.dart';

List<TrainingContentMember> _members(List<int> weights) => [
      for (var index = 0; index < weights.length; index++)
        TrainingContentMember(
          bankName: 'bank-$index',
          weightPercent: weights[index],
          position: index,
        ),
    ];

List<int> _weights(List<TrainingContentMember> members) =>
    members.map((member) => member.weightPercent).toList();

Map<String, int> _byBank(List<TrainingContentMember> members) => {
      for (final member in members) member.bankName: member.weightPercent,
    };

void main() {
  test(
      'equal shares use largest remainder for one, two, three and many members',
      () {
    for (final expected in [
      [100],
      [50, 50],
      [34, 33, 33],
      [15, 15, 14, 14, 14, 14, 14],
    ]) {
      expect(
        _weights(TrainingAllocation.equalize(
            _members(List.filled(expected.length, 0)))),
        expected,
      );
    }
    final large = TrainingAllocation.equalize(_members(List.filled(101, 0)));
    expect(_weights(large.take(100).toList()), everyElement(1));
    expect(large.last.weightPercent, 0);
    expect(large.fold(0, (sum, member) => sum + member.weightPercent), 100);
  });

  test(
      'remainder ties use position then exact bankName, independent of input order',
      () {
    final members = [
      TrainingContentMember(bankName: 'B', weightPercent: 50, position: 1),
      TrainingContentMember(bankName: 'Z', weightPercent: 50, position: 0),
    ];
    expect(
      TrainingAllocation.newQuestionQuotas(questionLimit: 1, members: members),
      {'B': 0, 'Z': 1},
    );
    final draft = [
      TrainingContentMember(bankName: 'B', weightPercent: 0, position: 0),
      TrainingContentMember(bankName: 'A', weightPercent: 0, position: 0),
      TrainingContentMember(bankName: 'C', weightPercent: 0, position: 0),
    ];
    expect(_byBank(TrainingAllocation.equalize(draft)),
        {'A': 34, 'B': 33, 'C': 33});
    expect(
      _byBank(TrainingAllocation.equalize(draft.reversed.toList())),
      _byBank(TrainingAllocation.equalize(draft)),
    );
    final saved = _members([34, 33, 33]);
    expect(
      TrainingAllocation.newQuestionQuotas(questionLimit: 2, members: saved),
      {'bank-0': 1, 'bank-1': 1, 'bank-2': 0},
    );
    expect(
      TrainingAllocation.newQuestionQuotas(
          questionLimit: 2, members: saved.reversed.toList()),
      TrainingAllocation.newQuestionQuotas(questionLimit: 2, members: saved),
    );
  });

  test('adjusted member is fixed while other weights keep relative proportions',
      () {
    final original = _members([50, 30, 20]);
    expect(
      _weights(TrainingAllocation.adjustWeight(original,
          bankName: 'bank-0', weightPercent: 60)),
      [60, 24, 16],
    );
    expect(
      _weights(TrainingAllocation.adjustWeight(original,
          bankName: 'bank-0', weightPercent: 0)),
      [0, 60, 40],
    );
    expect(
      _weights(TrainingAllocation.adjustWeight(original,
          bankName: 'bank-0', weightPercent: 100)),
      [100, 0, 0],
    );
    expect(_weights(original), [50, 30, 20]);
  });

  test(
      'zero-total peers split the remainder; existing zero peers otherwise stay zero',
      () {
    expect(
      _weights(TrainingAllocation.adjustWeight(_members([100, 0, 0]),
          bankName: 'bank-0', weightPercent: 21)),
      [21, 40, 39],
    );
    expect(
      _weights(TrainingAllocation.adjustWeight(_members([50, 50, 0]),
          bankName: 'bank-0', weightPercent: 20)),
      [20, 80, 0],
    );
  });

  test('single member stays at 100 and cannot be adjusted away from 100', () {
    expect(
      _weights(TrainingAllocation.adjustWeight(_members([100]),
          bankName: 'bank-0', weightPercent: 100)),
      [100],
    );
    expect(
      () => TrainingAllocation.adjustWeight(_members([100]),
          bankName: 'bank-0', weightPercent: 99),
      throwsFormatException,
    );
  });

  test('adding re-equalizes all selected members, including the first member',
      () {
    final added = TrainingContentMember(
        bankName: 'bank-2', weightPercent: 0, position: 2);
    expect(_weights(TrainingAllocation.addMember(_members([70, 30]), added)),
        [34, 33, 33]);
    expect(_weights(TrainingAllocation.addMember([], added)), [100]);
  });

  test(
      'deleting normalizes survivors, or splits equally if survivors are all zero',
      () {
    expect(
      _weights(TrainingAllocation.removeMember(_members([20, 30, 50]),
          bankName: 'bank-0')),
      [38, 62],
    );
    expect(
      _weights(TrainingAllocation.removeMember(_members([100, 0, 0]),
          bankName: 'bank-0')),
      [50, 50],
    );
    expect(
      _weights(TrainingAllocation.removeMember(_members([0, 100]),
          bankName: 'bank-0')),
      [100],
    );
    expect(
      () =>
          TrainingAllocation.removeMember(_members([100]), bankName: 'bank-0'),
      throwsFormatException,
    );
  });

  test('percentage edits preserve bindings and immutable result snapshots', () {
    final original = [
      TrainingContentMember(
        bankName: 'bank-0',
        weightPercent: 70,
        position: 3,
        bindingStatus: TrainingBindingStatus.invalidated,
        invalidationReason: TrainingBindingInvalidationReason.bankMissing,
      ),
      TrainingContentMember(bankName: 'bank-1', weightPercent: 30, position: 5),
    ];
    for (final result in [
      TrainingAllocation.equalize(original),
      TrainingAllocation.normalize(original),
      TrainingAllocation.adjustWeight(original,
          bankName: 'bank-1', weightPercent: 20),
    ]) {
      expect(result.first.bankName, 'bank-0');
      expect(result.first.position, 3);
      expect(result.first.bindingStatus, TrainingBindingStatus.invalidated);
      expect(result.first.invalidationReason,
          TrainingBindingInvalidationReason.bankMissing);
      expect(() => result.clear(), throwsUnsupportedError);
    }
    expect(_weights(original), [70, 30]);
  });

  test('invalid selections, targets and out-of-range adjustments fail safely',
      () {
    expect(() => TrainingAllocation.equalize([]), throwsFormatException);
    expect(() => TrainingAllocation.normalize([]), throwsFormatException);
    expect(
      () => TrainingAllocation.equalize([
        _members([100]).single,
        _members([0]).single
      ]),
      throwsFormatException,
    );
    expect(
      () => TrainingAllocation.addMember(_members([100]), _members([0]).single),
      throwsFormatException,
    );
    expect(
      () =>
          TrainingAllocation.removeMember(_members([100]), bankName: 'missing'),
      throwsFormatException,
    );
    for (final weight in [-1, 101]) {
      expect(
        () => TrainingAllocation.adjustWeight(_members([50, 50]),
            bankName: 'bank-0', weightPercent: weight),
        throwsFormatException,
      );
    }
    expect(
      () => TrainingAllocation.adjustWeight(_members([50, 50]),
          bankName: 'missing', weightPercent: 20),
      throwsFormatException,
    );
  });

  test('ideal quota example is exact; 0% stays zero even with earlier position',
      () {
    expect(
      TrainingAllocation.newQuestionQuotas(
          questionLimit: 20, members: _members([50, 30, 20])),
      {'bank-0': 10, 'bank-1': 6, 'bank-2': 4},
    );
    final result = TrainingAllocation.newQuestionQuotas(
        questionLimit: 1, members: _members([0, 50, 50]));
    expect(result, {'bank-0': 0, 'bank-1': 1, 'bank-2': 0});
    expect(() => result['bank-0'] = 1, throwsUnsupportedError);
  });

  test('ideal quotas reject unsaved distributions and invalid limits', () {
    for (final weights in <List<int>>[
      [],
      [0, 0],
      [50, 49],
      [100, 1]
    ]) {
      expect(
        () => TrainingAllocation.newQuestionQuotas(
            questionLimit: 20, members: _members(weights)),
        throwsFormatException,
      );
    }
    for (final limit in [0, 101]) {
      expect(
        () => TrainingAllocation.newQuestionQuotas(
            questionLimit: limit, members: _members([100])),
        throwsFormatException,
      );
    }
    expect(
      () => TrainingAllocation.newQuestionQuotas(questionLimit: 20, members: [
        _members([50]).single,
        _members([50]).single
      ]),
      throwsFormatException,
    );
  });

  test(
      'quota sum, rounding bounds and zero exclusion hold for every binary percentage and limit',
      () {
    for (var weight = 0; weight <= 100; weight++) {
      final members = _members([weight, 100 - weight, 0]);
      for (var limit = 1; limit <= 100; limit++) {
        final quotas = TrainingAllocation.newQuestionQuotas(
            questionLimit: limit, members: members);
        expect(quotas.values.fold(0, (sum, quota) => sum + quota), limit);
        expect(quotas['bank-2'], 0);
        for (final member in members) {
          final quota = quotas[member.bankName]!;
          final numerator = limit * member.weightPercent;
          expect(quota,
              inInclusiveRange(numerator ~/ 100, (numerator + 99) ~/ 100));
          if (member.weightPercent == 0) expect(quota, 0);
        }
      }
    }
  });

  test('all slider values preserve integer totals and exactly fix each target',
      () {
    for (final initial in [
      [34, 33, 33],
      [100, 0, 0],
      [50, 50, 0],
      [0, 0, 0]
    ]) {
      final members = _members(initial);
      for (var target = 0; target < members.length; target++) {
        for (var value = 0; value <= 100; value++) {
          final result = TrainingAllocation.adjustWeight(members,
              bankName: 'bank-$target', weightPercent: value);
          expect(result[target].weightPercent, value);
          expect(
              result.fold(0, (sum, member) => sum + member.weightPercent), 100);
          expect(_weights(result), everyElement(inInclusiveRange(0, 100)));
        }
      }
    }
  });
}
