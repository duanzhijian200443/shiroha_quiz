enum TrainingBindingStatus { valid, invalidated }

/// Fixed safe reasons, with no raw bank data, paths, or exception messages.
enum TrainingBindingInvalidationReason {
  bankMissing,
  categoryChanged,
  bankIneligible,
}

/// Immutable binding to an exact bankName, not a permanent bank entity ID.
final class TrainingContentMember {
  TrainingContentMember({
    required this.bankName,
    required this.weightPercent,
    required this.position,
    this.bindingStatus = TrainingBindingStatus.valid,
    this.invalidationReason,
  }) {
    if (bankName.trim().isEmpty) {
      throw const FormatException('Training member bank name is required.');
    }
    if (weightPercent < 0 || weightPercent > 100) {
      throw const FormatException('Training member weight must be 0..100.');
    }
    if (position < 0) {
      throw const FormatException(
          'Training member position must be non-negative.');
    }
    if (bindingStatus == TrainingBindingStatus.valid &&
        invalidationReason != null) {
      throw const FormatException(
          'Valid binding cannot have an invalidation reason.');
    }
  }

  final String bankName;
  final int weightPercent;
  final int position;
  final TrainingBindingStatus bindingStatus;

  /// Historical invalidated bindings may have no recorded reason.
  final TrainingBindingInvalidationReason? invalidationReason;

  TrainingContentMember withWeightPercent(int value) => TrainingContentMember(
        bankName: bankName,
        weightPercent: value,
        position: position,
        bindingStatus: bindingStatus,
        invalidationReason: invalidationReason,
      );

  @override
  bool operator ==(Object other) =>
      other is TrainingContentMember &&
      bankName == other.bankName &&
      weightPercent == other.weightPercent &&
      position == other.position &&
      bindingStatus == other.bindingStatus &&
      invalidationReason == other.invalidationReason;

  @override
  int get hashCode => Object.hash(
        bankName,
        weightPercent,
        position,
        bindingStatus,
        invalidationReason,
      );
}
