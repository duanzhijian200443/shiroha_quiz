import 'package:flutter/foundation.dart';

import '../../application/training/training_contracts.dart';
import '../../domain/training/category_key.dart';
import '../../domain/training/training_allocation.dart';
import '../../domain/training/training_content.dart';
import '../../domain/training/training_content_member.dart';

/// Local edits only. Commands receive a draft only after explicit Save.
final class TrainingContentDraft {
  TrainingContentDraft({
    required this.categoryKey,
    required this.preference,
    TrainingContent? content,
    int initialSortOrder = 0,
  })  : original = content,
        name = content?.name ?? '',
        questionLimit = content?.questionLimit ?? 20,
        sortOrder = content?.sortOrder ?? initialSortOrder,
        visualKey = preference.visualKey,
        members = List.of(content?.members ?? []);

  final CategoryKey categoryKey;
  TrainingCategoryPreference preference;
  TrainingContent? original;
  String name;
  int questionLimit;
  int sortOrder;
  CategoryVisualKey? visualKey;
  List<TrainingContentMember> members;

  bool get visualChanged => visualKey != preference.visualKey;

  /// Distinguishes a pure Category-visual edit from a content edit so a Save
  /// consumes only the independent CAS pair(s) it actually changed.
  bool get contentChanged {
    final current = original;
    if (current == null) return true;
    return name.trim() != current.name ||
        questionLimit != current.questionLimit ||
        sortOrder != current.sortOrder ||
        !listEquals(members, current.members);
  }

  bool get canSave => name.trim().isNotEmpty && members.isNotEmpty;
  TrainingContentEdit get edit => TrainingContentEdit(
        name: name,
        questionLimit: questionLimit,
        sortOrder: sortOrder,
        members: members,
      );

  Map<String, int> get quotas => members.isEmpty
      ? const {}
      : TrainingAllocation.newQuestionQuotas(
          questionLimit: questionLimit, members: members);

  void setBanks(List<String> names) {
    final previous = {for (final member in members) member.bankName: member};
    // Remember original invalidated bindings even after deselect/reselect.
    final originals = {
      for (final member in original?.members ?? <TrainingContentMember>[])
        member.bankName: member,
    };
    final added = names.any((name) => !previous.containsKey(name));
    final selected = [
      for (var i = 0; i < names.length; i++)
        _position(
            previous[names[i]] ??
                originals[names[i]] ??
                TrainingContentMember(
                    bankName: names[i], weightPercent: 0, position: i),
            i),
    ];
    members = selected.isEmpty
        ? []
        : added
            ? TrainingAllocation.equalize(selected)
            : TrainingAllocation.normalize(selected);
  }

  void adjustWeight(String bank, int percent) {
    members = TrainingAllocation.adjustWeight(members,
        bankName: bank, weightPercent: percent);
  }

  void moveMember(int from, int delta) {
    final to = from + delta;
    if (to < 0 || to >= members.length) return;
    final next = List.of(members);
    next.insert(to, next.removeAt(from));
    members = [for (var i = 0; i < next.length; i++) _position(next[i], i)];
  }

  /// Rebind is a separately confirmed durable action. Keep unsaved local fields,
  /// but use its exact returned revision and binding on subsequent Save.
  void acceptRebind(TrainingContent content, String bankName) {
    original = content;
    members = [
      for (final member in members)
        if (member.bankName == bankName)
          TrainingContentMember(
              bankName: member.bankName,
              weightPercent: member.weightPercent,
              position: member.position)
        else
          member,
    ];
  }

  static TrainingContentMember _position(TrainingContentMember member, int i) =>
      TrainingContentMember(
        bankName: member.bankName,
        weightPercent: member.weightPercent,
        position: i,
        bindingStatus: member.bindingStatus,
        invalidationReason: member.invalidationReason,
      );
}
