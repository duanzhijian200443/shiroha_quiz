import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';
import 'package:shiroha_quiz/application/backup/backup_restore_gate.dart';
import 'package:shiroha_quiz/application/generated_question/generated_local_authority.dart';
import 'package:shiroha_quiz/application/generated_question/generated_question_service.dart';
import 'package:shiroha_quiz/data/repositories/generated_local_authority_repository.dart';
import 'package:shiroha_quiz/domain/generated_question/generated_question_contract.dart';
import 'generated_test_support.dart';

Matcher identityFailure(GeneratedLocalIdentityFailure code) =>
    throwsA(isA<GeneratedLocalIdentityException>()
        .having((e) => e.failure, 'fixed identity failure', code));

final class _DelayedIdentity implements GeneratedLocalIdentityPort {
  final result = Completer<String>();
  @override
  Future<String> loadOrCreateOwner() => result.future;
}

final class _DelayedRead implements GeneratedLocalProposalReadPort {
  @override
  Future<List<GeneratedQuestionProposal>> completed(
          GeneratedLocalReadAuthority authority) =>
      throw UnimplementedError();
  @override
  Future<List<GeneratedReviewTargetChoice>> targets(
          GeneratedLocalReadAuthority authority) =>
      throw UnimplementedError();
  @override
  Future<List<Object?>> evidenceState(String proposalId, String itemId,
          GeneratedLocalReadAuthority authority) =>
      throw UnimplementedError();
  final started = Completer<void>();
  final result = Completer<List<GeneratedQuestionProposal>>();
  @override
  Future<List<GeneratedQuestionProposal>> pending(
      GeneratedLocalReadAuthority authority) {
    authority.validate();
    expect(authority as Object, isNot(isA<GeneratedLocalContext>()));
    started.complete();
    return result.future;
  }

  @override
  Future<GeneratedQuestionProposal> read(
          String proposalId, GeneratedLocalReadAuthority authority) =>
      throw UnimplementedError();
}

void main() {
  initializeGeneratedTests();
  late GeneratedHarness h;
  late GeneratedLocalAuthorityRepository repository;
  GeneratedLocalAuthorityFactory factory() => GeneratedLocalAuthorityFactory(
      identity: repository,
      proposals: repository,
      compositionIsCurrent: () =>
          !BackupRestoreMutationGate.instance.isMaintenance);
  setUp(() async {
    BackupRestoreMutationGate.resetForTesting();
    h = GeneratedHarness();
    await h.open();
    repository = GeneratedLocalAuthorityRepository(databaseHelper: h.helper);
  });
  tearDown(() async {
    await h.close();
    BackupRestoreMutationGate.resetForTesting();
  });

  test('concurrent factories mint one durable UUID; reopen never regenerates',
      () async {
    var minted = 0;
    GeneratedLocalAuthorityRepository contender() =>
        GeneratedLocalAuthorityRepository(
            databaseHelper: h.helper,
            idFactory: () {
              minted++;
              return const Uuid().v4();
            });
    final owners = await Future.wait(
        List.generate(8, (_) => contender().loadOrCreateOwner()));
    expect(owners.toSet(), hasLength(1));
    expect(minted, 1);
    final setting = await h.db.query('app_settings',
        where: 'key=?',
        whereArgs: [GeneratedLocalAuthorityRepository.ownerSettingKey]);
    expect(setting, [
      {
        'key': GeneratedLocalAuthorityRepository.ownerSettingKey,
        'value': owners.first
      }
    ]);
    await h.reopen();
    expect(await contender().loadOrCreateOwner(), owners.first);
    expect(minted, 1);
    expect(await h.db.getVersion(), 32);
  });

  test('missing setting with existing proposals stops without claiming them',
      () async {
    final original = await h.stage();
    await expectLater(factory().openSession(),
        identityFailure(GeneratedLocalIdentityFailure.missingWithProposals));
    expect(await h.db.query('app_settings'), isEmpty);
    expect((await h.repository.read(original.proposalId, h.local)).toJson(),
        original.toJson());
  });

  for (final value in [
    null,
    '',
    'owner',
    '11111111-1111-3111-8111-111111111111'
  ]) {
    test('present corrupt identity fails closed ($value)', () async {
      await h.db.insert('app_settings', {
        'key': GeneratedLocalAuthorityRepository.ownerSettingKey,
        'value': value
      });
      final before = await h.db.query('app_settings');
      await expectLater(factory().openSession(),
          identityFailure(GeneratedLocalIdentityFailure.corrupt));
      expect(await h.db.query('app_settings'), before);
    });
  }

  test('valid identity inconsistent with any proposal is never repaired',
      () async {
    final original = await h.stage();
    await h.db.insert('app_settings', {
      'key': GeneratedLocalAuthorityRepository.ownerSettingKey,
      'value': const Uuid().v4()
    });
    final before = await h.db.query('app_settings');
    await expectLater(factory().openSession(),
        identityFailure(GeneratedLocalIdentityFailure.ownerMismatch));
    expect(await h.db.query('app_settings'), before);
    expect((await h.repository.read(original.proposalId, h.local)).toJson(),
        original.toJson());
  });

  test('Inbox read has no target confirmation; foreign and absent IDs agree',
      () async {
    final session = await factory().openSession();
    expect(await session.pending(), isEmpty);
    final foreign = await h.stage();
    for (final id in [
      foreign.proposalId,
      '99999999-9999-4999-8999-999999999999'
    ]) {
      await expectLater(
          session.read(id), failure(GeneratedFailure.proposalUnavailable));
    }
    expect(await session.pending(), isEmpty);
    expect(await h.count('questions'), 0);
    expect(await h.count('generated_question_commit_receipts'), 0);
  });

  test(
      'explicit target is pinned; close and composition invalidation are final',
      () async {
    final authority = factory();
    final session = await authority.openSession();
    final context = session.confirmDisplayedTarget(h.target);
    expect(context.confirmedTarget.toJson(), h.target.toJson());
    expect(identical(context.confirmedTarget, h.target), isFalse);
    context.validate();
    session.close();
    expect(() => context.validate(), failure(GeneratedFailure.unauthorized));
    await expectLater(
        session.pending(), failure(GeneratedFailure.unauthorized));
    final next = await authority.openSession();
    final nextContext = next.confirmDisplayedTarget(h.target);
    authority.invalidate();
    expect(next.isCurrent, isFalse);
    expect(
        () => nextContext.validate(), failure(GeneratedFailure.unauthorized));
    await expectLater(
        authority.openSession(), failure(GeneratedFailure.unauthorized));
  });

  test('maintenance blocks reads, confirmation and identity initialization',
      () async {
    final authority = factory();
    final session = await authority.openSession();
    final context = session.confirmDisplayedTarget(h.target);
    BackupRestoreMutationGate.instance.tryEnterQuiescence();
    try {
      expect(session.isCurrent, isFalse);
      expect(() => context.validate(), failure(GeneratedFailure.unauthorized));
      expect(() => session.confirmDisplayedTarget(h.target),
          failure(GeneratedFailure.unauthorized));
      await expectLater(
          session.pending(), failure(GeneratedFailure.unauthorized));
      await expectLater(
          authority.openSession(), failure(GeneratedFailure.unauthorized));
    } finally {
      BackupRestoreMutationGate.instance.exitQuiescence();
    }
  });

  test('invalidation during async identity load releases no session', () async {
    final identity = _DelayedIdentity();
    final authority = GeneratedLocalAuthorityFactory(
        identity: identity,
        proposals: repository,
        compositionIsCurrent: () => true);
    final pending = authority.openSession();
    final check = expectLater(pending, failure(GeneratedFailure.unauthorized));
    authority.invalidate();
    identity.result.complete(const Uuid().v4());
    await check;
  });

  test('invalidation during read does not release stale results', () async {
    final read = _DelayedRead();
    final authority = GeneratedLocalAuthorityFactory(
        identity: repository,
        proposals: read,
        compositionIsCurrent: () => true);
    final session = await authority.openSession();
    final pending = session.pending();
    final check = expectLater(pending, failure(GeneratedFailure.unauthorized));
    await read.started.future;
    authority.invalidate();
    read.result.complete([]);
    await check;
  });
}
