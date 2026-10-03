import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/training/category_key.dart';
import 'package:shiroha_quiz/domain/training/training_content.dart';
import 'package:shiroha_quiz/domain/training/training_content_member.dart';

void main() {
  TrainingContentMember member(String bank, int weight, int position,
          {TrainingBindingStatus status = TrainingBindingStatus.valid}) =>
      TrainingContentMember(
        bankName: bank,
        weightPercent: weight,
        position: position,
        bindingStatus: status,
      );

  TrainingContent content({
    String id = 'content-a',
    String name = ' Training ',
    int limit = 40,
    int revision = 1,
    List<TrainingContentMember>? members,
  }) =>
      TrainingContent(
        contentId: id,
        categoryKey: const UncategorizedCategoryKey(),
        name: name,
        questionLimit: limit,
        sortOrder: 0,
        revision: revision,
        members: members ?? [member('Bank', 100, 0)],
      );

  test('identity is contentId, names are trimmed and may repeat', () {
    final first = content();
    final second = content(id: 'content-b');
    expect(first.name, 'Training');
    expect(second.name, first.name);
    expect(second.contentId, isNot(first.contentId));
    expect(content(id: ' opaque-id ').contentId, ' opaque-id ');
    for (final name in ['', ' \n\t']) {
      expect(() => content(name: name), throwsFormatException);
    }
    expect(() => content(id: ' '), throwsFormatException);
  });

  test('question limit 1 and 100 are valid; 0 and 101 are rejected', () {
    for (final limit in [1, 100]) {
      expect(content(limit: limit).questionLimit, limit);
    }
    for (final limit in [0, 101]) {
      expect(() => content(limit: limit), throwsFormatException);
    }
  });

  test('CAS revision must be positive', () {
    expect(content(revision: 2).revision, 2);
    for (final revision in [0, -1]) {
      expect(() => content(revision: revision), throwsFormatException);
    }
  });

  test('members are nonempty and have unique exact names and positions', () {
    expect(() => content(members: []), throwsFormatException);
    expect(
      () => content(members: [member('A', 50, 0), member('A', 50, 1)]),
      throwsFormatException,
    );
    expect(
      () => content(members: [member('A', 50, 0), member('B', 50, 0)]),
      throwsFormatException,
    );
    expect(
      content(members: [member('Math', 50, 0), member('math', 50, 1)]).members,
      hasLength(2),
    );
  });

  test('weights sum to 100 with a positive member, including single member',
      () {
    expect(content().members.single.weightPercent, 100);
    for (final members in [
      [member('A', 99, 0)],
      [member('A', 100, 0), member('B', 1, 1)],
      [member('A', 0, 0), member('B', 0, 1)],
    ]) {
      expect(() => content(members: members), throwsFormatException);
    }
    expect(
      content(members: [member('A', 100, 0), member('B', 0, 1)]).members,
      hasLength(2),
    );
  });

  test(
      'invalidated binding remains configured, including a zero-weight binding',
      () {
    final configuration = content(members: [
      member('A', 100, 0),
      member('B', 0, 1, status: TrainingBindingStatus.invalidated),
    ]);
    expect(configuration.hasValidBindings, isFalse);
    expect(configuration.members, hasLength(2));
    expect(configuration.members.last.bindingStatus,
        TrainingBindingStatus.invalidated);
    // Pure structural validation needs neither a bank catalog nor a database.
    expect(content().hasValidBindings, isTrue);
  });

  test('constructor owns an immutable snapshot of the member list', () {
    final source = [member('A', 100, 0)];
    final configuration = content(members: source);
    source.clear();
    expect(configuration.members.single.bankName, 'A');
    expect(() => configuration.members.clear(), throwsUnsupportedError);
  });
}
