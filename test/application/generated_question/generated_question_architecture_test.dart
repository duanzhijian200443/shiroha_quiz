import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/generated_question/generated_question_service.dart';
import 'package:shiroha_quiz/application/modules/module_composition.dart';
import 'package:shiroha_quiz/application/modules/generated_question_module.dart';
import 'package:shiroha_quiz/domain/conversations/conversation.dart';
import 'package:shiroha_quiz/services/backup/sha256.dart';
import '../modules/r5a_storage_baseline.dart';
import 'generated_test_support.dart';

void main() {
  initializeGeneratedTests();
  late GeneratedHarness h;
  setUp(() async {
    h = GeneratedHarness();
    await h.open();
  });
  tearDown(() async => h.close());
  test(
      'generated Domain/Application imports retain their dependency boundaries',
      () {
    for (final directory in [
      'lib/domain/generated_question',
      'lib/application/generated_question'
    ]) {
      for (final file in Directory(directory).listSync().whereType<File>()) {
        final source = file.readAsStringSync();
        final imports = RegExp(r'''(?:import|export)\s+['"]([^'"]+)['"]''')
            .allMatches(source)
            .map((m) => m[1]!)
            .toList();
        for (final forbidden in [
          'sqflite',
          'database_helper',
          '/data/',
          '/services/',
          'mcp_dart',
          'flutter',
          'dart:io',
          'dart:mirrors'
        ]) {
          expect(imports.any((v) => v.contains(forbidden)), isFalse,
              reason: '${file.path}: $forbidden');
        }
        for (final table in [
          'generated_question_proposals',
          'question_v2_payloads',
          'review_states'
        ]) {
          expect(source, isNot(contains(table)));
        }
      }
    }
    final repository =
        File('lib/data/repositories/generated_proposal_repository.dart')
            .readAsStringSync();
    expect(repository, contains('db.transaction(operation)'));
    expect(repository, isNot(contains('saveQuestionDraftsV2ToBank(')));
    expect(repository, isNot(contains('saveQuestionDraftsToBank(')));
    for (final file in [
      'lib/application/agent/agent_round_engine.dart',
      'lib/mcp/study_mcp_server.dart'
    ]) {
      final source = File(file).readAsStringSync();
      expect(source, isNot(contains('generated_question')));
    }
  });
  test(
      'internal module publishes typed read only, trusted command objects never become Agent/MCP/UI tools',
      () async {
    final p = await h.stage();
    final composition =
        const ModuleComposer().compose([generatedQuestionModule(h.service)]);
    expect(composition.agentSurface.projections, isEmpty);
    expect(composition.mcpSurface, isEmpty);
    expect(composition.uiContributions, hasLength(1));
    expect(composition.uiContributions.single.key, 'generated_proposal_review');
    expect(
        composition.uiContributions.single.slot, ModuleUiSlot.workspaceAction);
    expect(composition.capabilities.definitions.single.permission,
        CapabilityPermission.read);
    expect(
        composition.capabilities.definition(readGeneratedProposal), isNotNull);
    final context = CapabilityContext(
        principal: CapabilityPrincipal.builtInAgent,
        capabilities: [readGeneratedProposal],
        permissions: [CapabilityPermission.read],
        scope: ConversationScope.global(),
        authorizedScope: ConversationScope.global(),
        authorizationCurrent: () async => true);
    final executor = CapabilityExecutor(composition.capabilities);
    final result = await executor.execute(readGeneratedProposal,
        GeneratedProposalRead(p.proposalId, h.local), context);
    expect(result.receipt.status, CapabilityExecutionStatus.completed);
    expect(result.receipt.knownEffect, CapabilityEffect.none);
    expect(result.output!.proposalId, p.proposalId);
    final foreign = GeneratedLocalContext(
        localOwner: 'other', confirmedTarget: h.target, isCurrent: () => true);
    for (final id in [p.proposalId, '99999999-9999-4999-8999-999999999999']) {
      final outcome = await executor.execute(
          readGeneratedProposal, GeneratedProposalRead(id, foreign), context);
      expect(outcome.receipt.status,
          CapabilityExecutionStatus.failedWithoutEffect);
      expect(outcome.receipt.failure, CapabilityFailure.notFound);
    }
    h.authorized = false;
    final denied = await executor.execute(readGeneratedProposal,
        GeneratedProposalRead(p.proposalId, h.local), context);
    expect(denied.receipt.status, CapabilityExecutionStatus.notStarted);
    expect(denied.receipt.failure, CapabilityFailure.accessDenied);
    expect(
        const ModuleComposer().compose([]).capabilities.definitions, isEmpty);
  });
  test(
      'two exact hash exceptions reject missing/duplicated additions and unrelated old-source edits',
      () {
    final fixtures = jsonDecode(
        File('test/application/modules/fixtures/r5a_storage_additions.json')
            .readAsStringSync()) as Map;
    final entries = jsonDecode(
        File('test/application/modules/fixtures/retained_source_contracts.json')
            .readAsStringSync()) as List;
    String hash(String source) =>
        (StreamingSha256()..update(utf8.encode(source))).digestHex();
    for (final path in r5aStorageHashExceptions) {
      final current = File(path).readAsStringSync().replaceAll('\r\n', '\n');
      final expected = entries.singleWhere((e) => e['path'] == path)['sha256'];
      expect(hash(retainedR4StorageSource(path, current)), expected);
      expect(
          hash(retainedR4StorageSource(
              path, '$current\n// unrelated old source change\n')),
          isNot(expected));
      final addition = (fixtures[path] as List).last['after'] as String;
      expect(
          () =>
              retainedR4StorageSource(path, current.replaceFirst(addition, '')),
          throwsA(anything));
      expect(() => retainedR4StorageSource(path, '$current$addition'),
          throwsA(anything));
    }
    const source = 'unrelated source';
    expect(retainedR4StorageSource('lib/other.dart', source), source);
  });
}
