import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/generated_question/generated_local_authority.dart';
import 'package:shiroha_quiz/application/generated_question/generated_question_service.dart';
import 'package:shiroha_quiz/application/modules/module_composition.dart';
import 'package:shiroha_quiz/application/modules/generated_question_module.dart';
import 'package:shiroha_quiz/data/repositories/generated_local_authority_repository.dart';
import 'package:shiroha_quiz/domain/generated_question/generated_question_contract.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/ui/dependencies/generated_question_dependencies_scope.dart';
import 'package:shiroha_quiz/ui/generated_question/generated_proposal_controllers.dart';
import 'package:shiroha_quiz/ui/generated_question/generated_proposal_review_screen.dart';
import 'package:shiroha_quiz/ui/generated_question/generated_proposal_inbox_screen.dart';
import '../../application/generated_question/generated_test_support.dart';

export '../../application/generated_question/generated_test_support.dart';

class GeneratedUiHarness {
  final storage = GeneratedHarness();
  late GeneratedLocalAuthorityFactory authority;
  late GeneratedLocalAuthoritySession fixtureSession;
  Future<void> open() async {
    await storage.open();
    final repository =
        GeneratedLocalAuthorityRepository(databaseHelper: storage.helper);
    authority = GeneratedLocalAuthorityFactory(
        identity: repository,
        proposals: repository,
        compositionIsCurrent: () => true);
    fixtureSession = await authority.openSession();
  }

  Future<void> close() async {
    authority.invalidate();
    await storage.close();
  }

  Future<List<GeneratedEvidence>> addSource() async {
    const source = '11111111-1111-4111-8111-111111111111';
    String digest(String s) => List.filled(64, s).join();
    await storage.db.insert('library_files', {
      'file_id': 'source-file',
      'display_name': 'Synthetic.txt',
      'mime_type': 'text/plain',
      'storage_key': 'source-file/source',
      'size_bytes': 0,
      'sha256': digest('a'),
      'created_at': 1000
    });
    await storage.db.insert('parsed_artifact_heads',
        {'file_id': 'source-file', 'last_revision': 1});
    await storage.db.insert('parsed_artifacts', {
      'file_id': 'source-file',
      'artifact_id': source,
      'revision': 1,
      'source_sha256': digest('a'),
      'cache_key_version': 1,
      'cache_fingerprint': 'synthetic',
      'parser_route': 'synthetic',
      'parser_version': '1',
      'options_schema_version': 1,
      'payload_schema_version': 1,
      'storage_key': 'artifact/source-file',
      'payload_sha256': digest('b'),
      'size_bytes': 0,
      'published_at': 1000
    });
    return [
      GeneratedEvidence(
          evidenceKey: 'evidence',
          sourceRef: SourceRef.document(sourceId: source),
          fileId: 'source-file',
          artifactRevision: 1,
          artifactDigest: digest('b'))
    ];
  }

  GeneratedQuestionDependenciesScope dependencies(
          {Widget child = const SizedBox(),
          bool enabled = true,
          GeneratedQuestionService? service}) =>
      GeneratedQuestionDependenciesScope(
          authority: authority,
          service: service ?? storage.service,
          contributions: const ModuleComposer().compose([
            if (enabled) generatedQuestionModule(storage.service)
          ]).uiContributions,
          child: child);
  Future<GeneratedQuestionProposal> stage(
          {String key = 'ui-fixture',
          List<Map<String, Object?>>? items,
          int? requested,
          List<GeneratedEvidence> evidence = const []}) async =>
      (await storage.service.stage(
              submission(key: key, items: items, requested: requested),
              GeneratedOriginContext(
                  localOwner: fixtureSession.localOwner,
                  originKind: 'synthetic',
                  clientProfileId: 'ui-fixture',
                  target: storage.target,
                  evidence: evidence,
                  isCurrent: () => fixtureSession.isCurrent)))
          .proposal;
}

class ControlledGeneratedPersistence
    implements GeneratedQuestionPersistencePort {
  ControlledGeneratedPersistence(this.base);
  final GeneratedQuestionPersistencePort base;
  int flushCalls = 0, approveCalls = 0, rejectCalls = 0;
  Future<GeneratedQuestionProposal> Function(
      GeneratedReviewFlush, GeneratedLocalContext)? flushOverride;
  Future<GeneratedReceipt> Function(
      ApproveGeneratedProposalCommand, GeneratedLocalContext)? approveOverride;
  @override
  Future<GeneratedStageResult> stage(
          GeneratedStageInput input, GeneratedOriginContext context) =>
      base.stage(input, context);
  @override
  Future<GeneratedQuestionProposal> read(
          String id, GeneratedLocalContext context) =>
      base.read(id, context);
  @override
  Future<List<GeneratedQuestionProposal>> pending(
          GeneratedLocalContext context) =>
      base.pending(context);
  @override
  Future<List<Object?>> evidenceState(
          String id, String itemId, GeneratedLocalContext context) =>
      base.evidenceState(id, itemId, context);
  @override
  Future<GeneratedQuestionProposal> flush(
      GeneratedReviewFlush command, GeneratedLocalContext context) {
    flushCalls++;
    return flushOverride?.call(command, context) ??
        base.flush(command, context);
  }

  @override
  Future<GeneratedReceipt> approve(
      ApproveGeneratedProposalCommand command, GeneratedLocalContext context) {
    approveCalls++;
    return approveOverride?.call(command, context) ??
        base.approve(command, context);
  }

  @override
  Future<GeneratedQuestionProposal> reject(
      RejectGeneratedProposalCommand command, GeneratedLocalContext context) {
    rejectCalls++;
    return base.reject(command, context);
  }
}

Future<void> settleGenerated(WidgetTester tester) async {
  await tester.runAsync(() async {
    await tester.pump();
    for (final type in [
      GeneratedProposalReviewScreen,
      GeneratedProposalInboxScreen
    ]) {
      final finder = find.byType(type);
      if (finder.evaluate().isEmpty) continue;
      final state = tester.state(finder) as dynamic;
      final notifier = state.controller as ChangeNotifier;
      bool busy() => type == GeneratedProposalReviewScreen
          ? (notifier as GeneratedProposalReviewController).busy
          : (notifier as GeneratedProposalInboxController).isLoading;
      if (!busy()) continue;
      final done = Completer<void>();
      void check() {
        if (!busy()) {
          notifier.removeListener(check);
          done.complete();
        }
      }

      notifier.addListener(check);
      await done.future;
    }
  });
  await tester.pumpAndSettle();
}

Future<void> tapGenerated(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  // Scrolling changes layout on the next frame; hit-test that actual frame.
  await tester.pumpAndSettle();
  await tester.runAsync(() async {
    await tester.tap(finder);
    await tester.pump();
  });
  await settleGenerated(tester);
}
