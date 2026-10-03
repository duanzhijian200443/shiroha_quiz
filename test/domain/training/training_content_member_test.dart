import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/training/training_content_member.dart';

void main() {
  TrainingContentMember member({
    String bankName = 'Bank',
    int weight = 100,
    int position = 0,
    TrainingBindingStatus status = TrainingBindingStatus.valid,
    TrainingBindingInvalidationReason? reason,
  }) =>
      TrainingContentMember(
        bankName: bankName,
        weightPercent: weight,
        position: position,
        bindingStatus: status,
        invalidationReason: reason,
      );

  test('bankName remains exact and blank names are rejected', () {
    expect(member(bankName: ' 数学 ').bankName, ' 数学 ');
    expect(member(bankName: 'Math'), isNot(member(bankName: 'math')));
    for (final name in ['', ' \t\n']) {
      expect(() => member(bankName: name), throwsFormatException);
    }
  });

  test('integer weight bounds include 0 and 100; position is non-negative', () {
    for (final weight in [0, 1, 99, 100]) {
      expect(member(weight: weight).weightPercent, weight);
    }
    for (final weight in [-1, 101]) {
      expect(() => member(weight: weight), throwsFormatException);
    }
    expect(() => member(position: -1), throwsFormatException);
    expect(member(position: 5).position, 5);
  });

  test('valid binding cannot carry invalidation history', () {
    expect(member().bindingStatus, TrainingBindingStatus.valid);
    expect(member().invalidationReason, isNull);
    for (final reason in TrainingBindingInvalidationReason.values) {
      expect(() => member(reason: reason), throwsFormatException);
      final invalidated = member(
        status: TrainingBindingStatus.invalidated,
        reason: reason,
      );
      expect(invalidated.bindingStatus, TrainingBindingStatus.invalidated);
      expect(invalidated.invalidationReason, reason);
    }
    expect(member(status: TrainingBindingStatus.invalidated).invalidationReason,
        isNull);
  });

  test('weight changes preserve exact binding identity and invalidation', () {
    final original = member(
      bankName: ' 数学 ',
      position: 7,
      status: TrainingBindingStatus.invalidated,
      reason: TrainingBindingInvalidationReason.categoryChanged,
    );
    final changed = original.withWeightPercent(0);
    expect(changed.bankName, original.bankName);
    expect(changed.position, original.position);
    expect(changed.bindingStatus, original.bindingStatus);
    expect(changed.invalidationReason, original.invalidationReason);
    expect(changed.weightPercent, 0);
    expect(original.weightPercent, 100);
  });

  test('member equality and hash cover all value fields', () {
    expect(member(), member());
    expect(member().hashCode, member().hashCode);
    expect(member(), isNot(member(weight: 0)));
    expect(member(), isNot(member(position: 1)));
    expect(member(), isNot(member(status: TrainingBindingStatus.invalidated)));
    expect(
      member(status: TrainingBindingStatus.invalidated),
      isNot(member(
        status: TrainingBindingStatus.invalidated,
        reason: TrainingBindingInvalidationReason.bankMissing,
      )),
    );
  });
}
