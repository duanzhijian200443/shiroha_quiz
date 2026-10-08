import 'package:shiroha_quiz/application/safe_write/agent_write_persistence.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/application/study_plan/study_plan_ports.dart';
import 'package:shiroha_quiz/domain/study_plan/study_plan_values.dart';
import 'package:shiroha_quiz/domain/conversations/conversation.dart';
import 'package:shiroha_quiz/application/retrieval/retrieval.dart';
import 'package:shiroha_quiz/application/retrieval/retrieval_ports.dart';
import 'package:shiroha_quiz/domain/retrieval/retrieval_chunk.dart';
import 'package:shiroha_quiz/domain/source/source_document.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';

final class ModuleWritePort implements AgentWritePersistencePort {
  int admissions = 0;
  int commits = 0;
  bool available = true;
  @override
  Future<AgentWriteAdmissionResult> admitStagingTarget(
      AgentWriteAdmissionRequest request) async {
    admissions++;
    if (!available) return const AgentWriteAdmissionDenied();
    return AgentWriteAdmissionGranted(AgentWriteAdmittedTarget(
        storageId: 'q1',
        bankName: 'Synthetic',
        draft: QuestionDraftV2(
            questionId: 'q1',
            kind: QuestionKind.shortAnswer,
            stem: RichContent(nodes: const [TextNode('Safe stem')]))));
  }

  @override
  Future<void> commitApproved(AgentWriteCommitRequest request) async {
    commits++;
  }
}

final class ModulePlanningPort implements StudyPlanPlanningPort {
  int reads = 0;
  bool available = true;
  @override
  Future<StudyPlanPlanningAdmission> loadPlanningContext(
      {required ConversationScope sourceScope,
      required String bankName,
      required DateTime now}) async {
    reads++;
    return available
        ? StudyPlanPlanningAdmitted(StudyPlanPlanningContext(
            bankName: bankName,
            questionCount: 10,
            masteredCount: 1,
            dueCount: 2,
            weakCount: 3,
            newCount: 4))
        : const StudyPlanPlanningUnavailable();
  }
}

final class ModuleSource implements RetrievalArtifactSourcePort {
  int loads = 0;
  final identity = RetrievalArtifactSnapshot(
      fileId: 'file-1',
      artifactId: 'artifact-1',
      revision: 1,
      payloadDigest: 'a' * 64);
  @override
  Future<
      ({
        String? displayLabel,
        RetrievalArtifactSnapshot identity,
        SourceDocument sourceDocument
      })> loadCurrent(String fileId) async {
    loads++;
    return (
      identity: identity,
      displayLabel: 'public.txt',
      sourceDocument: SourceDocument(sourceId: 'artifact-1', parts: [
        SourceContentPart(
            sourceRef: SourceRef.document(sourceId: 'artifact-1'),
            content: RichContent(nodes: const [TextNode('function')]))
      ])
    );
  }

  @override
  Future<RetrievalArtifactSnapshot?> readCurrentIdentity(String fileId) async =>
      identity;
}

final class ModuleScope implements RetrievalScopeResolverPort {
  int calls = 0;
  RetrievalFailure? failure;
  @override
  Future<List<String>> resolveFileIds(RetrievalScopeRequest scope) async {
    calls++;
    if (failure case final error?) throw RetrievalException(error);
    return ['file-1'];
  }
}

final class ModuleIndex
    implements RetrievalIndexPort, RetrievalIndexEvidencePort {
  ModuleIndex(this.effect);
  final RetrievalBuildEffect effect;
  int builds = 0;
  void Function()? onBuildCommitted;
  bool lostBuildResponse = false;
  bool failSearch = false;
  @override
  Future<void> ensureBuild(
      {required RetrievalArtifactSnapshot snapshot,
      required String chunkerVersion,
      required String lexicalProjectionVersion,
      required List<RetrievalChunk> chunks}) async {
    builds++;
  }

  @override
  Future<RetrievalBuildEffect> ensureBuildWithEvidence(
      {required RetrievalArtifactSnapshot snapshot,
      required String chunkerVersion,
      required String lexicalProjectionVersion,
      required List<RetrievalChunk> chunks}) async {
    builds++;
    if (lostBuildResponse) throw StateError('lost response');
    onBuildCommitted?.call();
    return effect;
  }

  @override
  Future<RetrievalIndexSearchResult> search(
      {required List<RetrievalArtifactSnapshot> snapshots,
      required String matchExpression,
      required int limit,
      required int maxHitBytes,
      required int maxResultBytes}) async {
    if (failSearch) throw StateError('private marker');
    return RetrievalIndexSearchResult(
        hits: const [], sourceChangedFileIds: const []);
  }

  @override
  Future<void> removeIndex(String fileId) async {}
  @override
  Future<void> removeIndexGeneration(
      RetrievalArtifactSnapshot snapshot) async {}
}
