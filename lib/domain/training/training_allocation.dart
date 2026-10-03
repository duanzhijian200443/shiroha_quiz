import 'training_content.dart';
import 'training_content_member.dart';

/// Pure V3 percentage editing and ideal new-question quotas.
///
/// Editing accepts draft distributions (including all-zero weights). Saved
/// configuration additionally requires unique positions and weights summing to
/// 100 through [TrainingContent]. Result lists preserve input order/bindings.
final class TrainingAllocation {
  const TrainingAllocation._();

  static List<TrainingContentMember> equalize(
    List<TrainingContentMember> members,
  ) {
    _validateSelection(members);
    return _withWeights(members, _allocate(100, members, equal: true));
  }

  static List<TrainingContentMember> normalize(
    List<TrainingContentMember> members,
  ) {
    _validateSelection(members);
    return _withWeights(members, _allocate(100, members));
  }

  static List<TrainingContentMember> adjustWeight(
    List<TrainingContentMember> members, {
    required String bankName,
    required int weightPercent,
  }) {
    _validateSelection(members);
    if (weightPercent < 0 || weightPercent > 100) {
      throw const FormatException('Training member weight must be 0..100.');
    }
    final target = members.indexWhere((member) => member.bankName == bankName);
    if (target < 0) {
      throw const FormatException(
          'Training allocation target is not selected.');
    }
    if (members.length == 1) {
      if (weightPercent != 100) {
        throw const FormatException(
            'Single training member must have weight 100.');
      }
      return _withWeights(members, [100]);
    }
    final others =
        members.where((member) => member.bankName != bankName).toList();
    final otherWeights = _allocate(100 - weightPercent, others);
    var otherIndex = 0;
    return List.unmodifiable([
      for (var index = 0; index < members.length; index++)
        members[index].withWeightPercent(
          index == target ? weightPercent : otherWeights[otherIndex++],
        ),
    ]);
  }

  static List<TrainingContentMember> addMember(
    List<TrainingContentMember> members,
    TrainingContentMember member,
  ) =>
      equalize([...members, member]);

  static List<TrainingContentMember> removeMember(
    List<TrainingContentMember> members, {
    required String bankName,
  }) {
    _validateSelection(members);
    if (!members.any((member) => member.bankName == bankName)) {
      throw const FormatException(
          'Training allocation target is not selected.');
    }
    return normalize(
        members.where((member) => member.bankName != bankName).toList());
  }

  /// Includes zero-weight members with quota 0. Invalidated bindings are not
  /// repaired or filtered here; runtime usability admission is a later stage.
  /// No candidate counts, sampling or shortage refill are performed.
  static Map<String, int> newQuestionQuotas({
    required int questionLimit,
    required List<TrainingContentMember> members,
  }) {
    validateTrainingQuestionLimit(questionLimit);
    validateTrainingMemberWeights(members);
    final quotas = _allocate(questionLimit, members);
    return Map.unmodifiable({
      for (var index = 0; index < members.length; index++)
        members[index].bankName: quotas[index],
    });
  }

  static void _validateSelection(List<TrainingContentMember> members) {
    if (members.isEmpty) {
      throw const FormatException(
          'Training allocation needs at least one member.');
    }
    final bankNames = <String>{};
    for (final member in members) {
      if (!bankNames.add(member.bankName)) {
        throw const FormatException(
            'Training member bank names must be unique.');
      }
    }
  }

  static List<TrainingContentMember> _withWeights(
    List<TrainingContentMember> members,
    List<int> weights,
  ) =>
      List.unmodifiable([
        for (var index = 0; index < members.length; index++)
          members[index].withWeightPercent(weights[index]),
      ]);

  /// Largest Remainder using integer numerator, quotient and remainder only.
  static List<int> _allocate(
    int total,
    List<TrainingContentMember> members, {
    bool equal = false,
  }) {
    final sum = members.fold(0, (sum, member) => sum + member.weightPercent);
    final useEqualWeights = equal || sum == 0;
    final denominator = useEqualWeights ? members.length : sum;
    final numerators = [
      for (final member in members)
        total * (useEqualWeights ? 1 : member.weightPercent),
    ];
    final result = [
      for (final numerator in numerators) numerator ~/ denominator
    ];
    final remaining = total - result.fold(0, (sum, value) => sum + value);
    final order = List.generate(members.length, (index) => index)
      // Zero weights cannot receive a remainder seat, even as fallback.
      ..removeWhere(
          (index) => !useEqualWeights && members[index].weightPercent == 0)
      ..sort((left, right) {
        final remainderOrder = (numerators[right] % denominator)
            .compareTo(numerators[left] % denominator);
        if (remainderOrder != 0) return remainderOrder;
        final positionOrder =
            members[left].position.compareTo(members[right].position);
        if (positionOrder != 0) return positionOrder;
        return members[left].bankName.compareTo(members[right].bankName);
      });
    for (var index = 0; index < remaining; index++) {
      result[order[index]]++;
    }
    return result;
  }
}
