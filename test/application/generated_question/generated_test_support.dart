import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shiroha_quiz/application/generated_question/generated_question_service.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/repositories/generated_proposal_repository.dart';
import 'package:shiroha_quiz/domain/generated_question/generated_question_contract.dart';
import 'package:uuid/uuid.dart';

Map<String, Object?> candidate(
        {String key = 'item',
        String stem = 'Synthetic stem',
        String kind = 'shortAnswer',
        List<String> evidence = const []}) =>
    {
      'itemKey': key,
      'kind': kind,
      'stem': [
        {'type': 'text', 'text': stem}
      ],
      'options': kind == 'singleChoice'
          ? [
              {
                'optionKey': 'a',
                'label': 'A',
                'content': [
                  {'type': 'text', 'text': 'First'}
                ]
              },
              {
                'optionKey': 'b',
                'label': 'B',
                'content': [
                  {'type': 'text', 'text': 'Second'}
                ]
              },
            ]
          : [],
      'answer': kind == 'singleChoice'
          ? {
              'type': 'choice',
              'optionKeys': ['a']
            }
          : {
              'type': 'content',
              'content': [
                {'type': 'text', 'text': 'Synthetic answer'}
              ]
            },
      'explanation': [],
      'evidenceKeys': evidence,
    };
String submission(
        {String key = 'submission',
        List<Map<String, Object?>>? items,
        int? requested}) =>
    jsonEncode({
      'schemaVersion': 1,
      'submissionKey': key,
      'requestedCount': requested ?? items?.length ?? 1,
      'items': items ?? [candidate()],
    });
Matcher failure(GeneratedFailure code) =>
    throwsA(isA<GeneratedQuestionException>()
        .having((e) => e.failure, 'fixed failure', code));

final class GeneratedHarness {
  final helper = DatabaseHelper.instance;
  late Directory temp;
  late Database db;
  late GeneratedProposalRepository repository;
  late GeneratedQuestionService service;
  bool authorized = true;
  GeneratedTarget target = GeneratedTarget(
      bankName: 'bank',
      folderName: 'folder',
      projectId: null,
      projectBankNames: const []);
  GeneratedLocalContext get local => GeneratedLocalContext(
      localOwner: 'owner',
      confirmedTarget: target,
      isCurrent: () => authorized);
  GeneratedOriginContext origin(
          {List<GeneratedEvidence> evidence = const [],
          String profile = 'internal'}) =>
      GeneratedOriginContext(
          localOwner: 'owner',
          originKind: 'synthetic',
          clientProfileId: profile,
          target: target,
          evidence: evidence,
          isCurrent: () => authorized);
  Future<void> open() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    temp = await Directory.systemTemp.createTemp('r5a_synthetic_');
    DatabaseHelper.configureRuntimeProfile(DatabaseRuntimeProfile.explicitFile,
        databasePath: p.join(temp.path, 'live'));
    db = await helper.database;
    await db
        .insert('bank_folders', {'bank_name': 'bank', 'folder_name': 'folder'});
    repository = GeneratedProposalRepository(databaseHelper: helper);
    service = GeneratedQuestionService(repository,
        admission: GeneratedQuestionAdmission(idFactory: const Uuid().v4));
  }

  Future<void> reopen() async {
    await helper.close();
    db = await helper.database;
  }

  Future<void> close() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    await temp.delete(recursive: true);
  }

  Future<GeneratedQuestionProposal> stage(
          {String key = 'submission',
          List<Map<String, Object?>>? items,
          List<GeneratedEvidence> evidence = const []}) async =>
      (await service.stage(
              submission(key: key, items: items), origin(evidence: evidence)))
          .proposal;
  Future<GeneratedQuestionProposal> flush(
          GeneratedQuestionProposal proposal, List<Object?> ops) =>
      service.flush(
          GeneratedReviewFlush.fromJson({
            'proposalId': proposal.proposalId,
            'expectedReviewRevision': proposal.reviewRevision,
            'operations': ops
          }),
          local);
  Future<GeneratedQuestionProposal> decide(GeneratedQuestionProposal proposal,
          {bool accepted = true}) =>
      flush(proposal, [
        for (final i in proposal.items)
          {
            'type': 'decide',
            'itemId': i.itemId,
            'decision': accepted ? 'accepted' : 'rejected'
          }
      ]);
  ApproveGeneratedProposalCommand approval(GeneratedQuestionProposal proposal,
          {List<String>? ids, int? revision}) =>
      ApproveGeneratedProposalCommand.fromJson({
        'proposalId': proposal.proposalId,
        'expectedReviewRevision': revision ?? proposal.reviewRevision,
        'approvedItemIds': ids ??
            proposal.items
                .where((i) => i.decision == GeneratedDecision.accepted)
                .map((i) => i.itemId)
                .toList()
      });
  Future<int> count(String table) async =>
      (await db.rawQuery('SELECT COUNT(*) FROM $table')).single.values.single
          as int;
}

void initializeGeneratedTests() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
}
