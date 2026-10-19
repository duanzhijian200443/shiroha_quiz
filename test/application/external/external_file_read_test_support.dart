import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/application/external/external_file_read.dart';
import 'package:shiroha_quiz/application/external/external_read_context.dart';
import 'package:shiroha_quiz/application/external/external_runtime_admission.dart';
import 'package:shiroha_quiz/application/parsed_artifacts/parsed_artifact_lifecycle.dart';
import 'package:shiroha_quiz/application/retrieval/retrieval.dart';
import 'package:shiroha_quiz/application/retrieval/retrieval_ports.dart';
import 'package:shiroha_quiz/data/repositories/external_file_read_repository.dart';
import 'package:shiroha_quiz/data/repositories/external_question_read_repository.dart';
import 'package:shiroha_quiz/data/repositories/content_asset_reclamation_observation_repository.dart';
import 'package:shiroha_quiz/data/repositories/external_target_read_repository.dart';
import 'package:shiroha_quiz/data/repositories/library_file_repository.dart';
import 'package:shiroha_quiz/data/repositories/parsed_artifact_repository.dart';
import 'package:shiroha_quiz/data/repositories/retrieval_index_repository.dart';
import 'package:shiroha_quiz/domain/assets/library_file.dart';
import 'package:shiroha_quiz/domain/assets/asset_ref.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/retrieval/retrieval_chunk.dart';
import 'package:shiroha_quiz/domain/source/source_document.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/services/file_library/managed_artifact_storage_adapter.dart';
import 'package:shiroha_quiz/services/parsed_artifacts/parsed_artifact_lifecycle_service.dart';
import 'package:shiroha_quiz/services/retrieval/deterministic_source_chunker.dart';
import 'durable_stage_test_support.dart';

export 'durable_stage_test_support.dart';

/// Synthetic generator only seeds the real F1 lifecycle before external reads.
final class FileGeneration implements ParsedArtifactGenerationPort {
  int calls = 0;
  bool longFormula = false;
  @override
  Future<ParsedArtifactGenerationPlan> resolvePlan(
          {required LibraryFile file,
          required ParsedArtifactParseOptions options}) async =>
      const ParsedArtifactGenerationPlan(
          parserRoute: 'txt', parserVersion: '1', optionsSchemaVersion: 1);
  @override
  Future<SourceDocument> generate(
      {required LibraryFile file,
      required String artifactId,
      required ParsedArtifactGenerationPlan plan}) async {
    calls++;
    SourceRef ref(int i) => SourceRef.at(
        sourceId: artifactId,
        point:
            SourcePoint.block(pageNumber: 1, blockId: 'b$i', readingOrder: i));
    RichContent text(String value) => RichContent(nodes: [TextNode(value)]);
    return SourceDocument(sourceId: artifactId, parts: [
      for (var i = 0; i < 10; i++)
        SourceContentPart(
            sourceRef: ref(i),
            content: text(i == 0 ? 'needle ${file.fileId}' : 'paragraph $i'),
            role: SourceContentRole.paragraph),
      SourceContentPart(
          sourceRef: ref(10),
          role: SourceContentRole.formula,
          content: RichContent(
              nodes: [BlockMathNode(longFormula ? 'x' * 1500 : 'x^2')])),
      SourceContentPart(
          sourceRef: ref(11),
          content: RichContent(nodes: [
            const TextNode('safe tail'),
            RawFallbackNode({
              'type': 'raw_fallback',
              'payload': {'opaque': 'never-release-raw'}
            })
          ])),
      SourceTablePart(sourceRef: ref(12), rows: [
        [text('table value')]
      ]),
      SourceAssetPart(
          sourceRef: ref(13),
          asset: AssetRef(
              assetId: 'image-1', kind: AssetKind.image, mimeType: 'image/png'),
          alternativeText: text('safe alt')),
      UnsupportedSourcePart(
          sourceRef: ref(14),
          kindCode: 'opaque',
          fallbackContent: text('never-release-unsupported')),
    ]);
  }
}

/// Checkpoints surround real index transactions/FTS, not policy mocks.
final class FileIndexBarrier
    implements RetrievalIndexPort, RetrievalIndexEvidencePort {
  FileIndexBarrier(this.inner);
  final SqliteRetrievalIndexRepository inner;
  Future<void> Function()? afterSearch, beforeBuild, afterBuild;
  bool loseBuildResponse = false;
  final searched = <String>[];
  @override
  Future<RetrievalBuildEffect> ensureBuildWithEvidence(
      {required RetrievalArtifactSnapshot snapshot,
      required String chunkerVersion,
      required String lexicalProjectionVersion,
      required List<RetrievalChunk> chunks}) async {
    await beforeBuild?.call();
    final effect = await inner.ensureBuildWithEvidence(
        snapshot: snapshot,
        chunkerVersion: chunkerVersion,
        lexicalProjectionVersion: lexicalProjectionVersion,
        chunks: chunks);
    await afterBuild?.call();
    if (loseBuildResponse) {
      throw const RetrievalException(RetrievalFailure.internalError);
    }
    return effect;
  }

  @override
  Future<void> ensureBuild(
      {required RetrievalArtifactSnapshot snapshot,
      required String chunkerVersion,
      required String lexicalProjectionVersion,
      required List<RetrievalChunk> chunks}) async {
    await ensureBuildWithEvidence(
        snapshot: snapshot,
        chunkerVersion: chunkerVersion,
        lexicalProjectionVersion: lexicalProjectionVersion,
        chunks: chunks);
  }

  @override
  Future<RetrievalIndexSearchResult> search(
      {required List<RetrievalArtifactSnapshot> snapshots,
      required String matchExpression,
      required int limit,
      required int maxHitBytes,
      required int maxResultBytes}) async {
    searched.addAll(snapshots.map((f) => f.fileId));
    final result = await inner.search(
        snapshots: snapshots,
        matchExpression: matchExpression,
        limit: limit,
        maxHitBytes: maxHitBytes,
        maxResultBytes: maxResultBytes);
    await afterSearch?.call();
    return result;
  }

  @override
  Future<void> removeIndex(String fileId) => inner.removeIndex(fileId);
  @override
  Future<void> removeIndexGeneration(RetrievalArtifactSnapshot snapshot) =>
      inner.removeIndexGeneration(snapshot);
}

/// Observes actual verified F1 reads without replacing payload/identity checks.
final class ObservedF1 implements ParsedArtifactLifecyclePort {
  ObservedF1(this.inner);
  final ParsedArtifactLifecyclePort inner;
  int reads = 0;
  Future<void> Function()? afterRead;
  @override
  Future<ParsedArtifactSnapshot> getCurrentArtifact(String fileId) async {
    reads++;
    final verified = await inner.getCurrentArtifact(fileId);
    await afterRead?.call();
    return verified;
  }

  @override
  Future<ParsedArtifactEnsureResult> ensureParsedArtifact(
          {required String fileId,
          required ParsedArtifactParseOptions options}) =>
      inner.ensureParsedArtifact(fileId: fileId, options: options);
  @override
  Future<ParsedArtifactEnsureResult> reparseArtifact(
          {required String fileId,
          required ParsedArtifactParseOptions options,
          required int expectedRevision}) =>
      inner.reparseArtifact(
          fileId: fileId, options: options, expectedRevision: expectedRevision);
  @override
  Future<void> removeCurrentArtifact(
          {required String fileId, required int expectedRevision}) =>
      inner.removeCurrentArtifact(
          fileId: fileId, expectedRevision: expectedRevision);
}

final class FileReadHarness {
  final s = DurableStageHarness();
  final generation = FileGeneration();
  late ParsedArtifactRepository metadata;
  late ParsedArtifactLifecycleService lifecycle;
  late ExternalReadContextService read;
  late FileIndexBarrier index;
  late ObservedF1 observed;
  late Directory managed;
  int revision = 1;
  String? project;
  static const options = ParsedArtifactParseOptions(
      routeSelection: ParsedArtifactRouteSelection.auto);
  Future<void> open({bool learningSpace = true}) async {
    await s.open();
    if (learningSpace) {
      project = 'space';
      await s.h.db.insert('projects', {
        'project_id': project,
        'display_name': 'Synthetic',
        'created_at': 1
      });
      await s.h.db.insert(
          'project_banks', {'project_id': project, 'bank_name': 'bank'});
    }
    managed = Directory(p.join(s.h.temp.path, 'managed'))..createSync();
    metadata = ParsedArtifactRepository(databaseHelper: s.h.helper);
    lifecycle = ParsedArtifactLifecycleService(
        libraryFileRepository:
            LibraryFileRepository(databaseHelper: s.h.helper),
        artifactRepository: metadata,
        artifactStorage: ManagedArtifactStorageAdapter(managedRoot: managed),
        generationPort: generation,
        reclamationReset: ContentAssetReclamationObservationRepository(
            databaseHelper: s.h.helper));
    await seed('file-a');
    await seed('file-b');
    await grant();
    compose();
  }

  ExternalGrantScope get bank => ExternalGrantScope(
      kind: ExternalTargetKind.bank, targetId: 'bank', projectId: project);
  ExternalGrantScope file(String id, {String? space}) => ExternalGrantScope(
      kind: ExternalTargetKind.file, targetId: id, projectId: space ?? project);
  Future<void> grant(
      {List<ExternalGrantScope>? scopes,
      List<ExternalContentCategory>? categories}) async {
    await s.management.replaceGrant(
        s.profile,
        revision,
        s.policy(
            permissions: [
              CapabilityPermission.read,
              CapabilityPermission.stage
            ],
            scopes: scopes ?? [bank, file('file-a'), file('file-b')],
            categories: categories ?? ExternalContentCategory.values));
    revision++;
  }

  Future<void> seed(String id, {bool parsed = true}) async {
    final original = File(p.join(managed.path, 'library', id));
    await original.parent.create(recursive: true);
    await original.writeAsString('abc');
    await LibraryFileRepository(databaseHelper: s.h.helper).save(LibraryFile(
        fileId: id,
        displayName: 'same-name.txt',
        mimeType: 'text/plain',
        sizeBytes: 3,
        sha256:
            'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
        storageKey: 'library/$id',
        createdAt: DateTime.utc(2026)));
    if (project != null) {
      await s.h.db
          .insert('project_files', {'project_id': project, 'file_id': id});
    }
    if (parsed) {
      await lifecycle.ensureParsedArtifact(fileId: id, options: options);
    }
  }

  void compose(
      {int maxHandles = 256,
      int maxBytes = 32768,
      ExternalRuntimeAdmission? admission,
      Duration timeout = const Duration(seconds: 2)}) {
    index = FileIndexBarrier(
        SqliteRetrievalIndexRepository(databaseHelper: s.h.helper));
    observed = ObservedF1(lifecycle);
    read = ExternalReadContextService(
        admission: admission ?? s.service.runtimeAdmission,
        targets: SqliteExternalTargetReadRepository(databaseHelper: s.h.helper),
        questions:
            SqliteExternalQuestionReadRepository(databaseHelper: s.h.helper),
        files: ExternalFileReader(
            authorization:
                SqliteExternalFileReadRepository(databaseHelper: s.h.helper),
            source: ExternalVerifiedArtifactSource(
                lifecycle: observed, metadata: metadata),
            index: index,
            chunker: const DeterministicSourceChunker()),
        maxActiveHandles: maxHandles,
        maxResponseBytes: maxBytes,
        maxQueryDuration: timeout);
  }

  Future<String> context() async {
    final target = (await read.listTargets(session: s.session)).items.single;
    return read.createContext(session: s.session, targetRef: target.targetRef);
  }

  Future<String> approved({String? parent}) async {
    parent ??= await context();
    final files =
        await read.listFileSelections(session: s.session, context: parent);
    return read.createFileContext(
        session: s.session,
        context: parent,
        fileRefs: [files.items.first['fileRef'] as String]);
  }

  Future<ExternalFilePage> search(String context, {String query = 'needle'}) =>
      read.retrieveFileContent(
          session: s.session, context: context, query: query);
  Future<ExternalFilePage> passage(String context, String ref,
          {String? cursor}) =>
      read.getFilePassage(
          session: s.session,
          context: context,
          passageRef: ref,
          cursor: cursor);
  Future<void> close() async {
    read.close();
    await read.whenIdle;
    await s.close();
  }
}
