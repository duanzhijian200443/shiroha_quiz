import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/application/agent/agent_retrieval_tool.dart';
import 'package:shiroha_quiz/application/retrieval/retrieval.dart';
import 'package:shiroha_quiz/application/retrieval/retrieval_ports.dart';
import 'package:shiroha_quiz/application/retrieval/retrieval_service.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/repositories/library_file_repository.dart';
import 'package:shiroha_quiz/data/repositories/parsed_artifact_repository.dart';
import 'package:shiroha_quiz/data/repositories/retrieval_index_repository.dart';
import 'package:shiroha_quiz/domain/assets/library_file.dart';
import 'package:shiroha_quiz/services/file_library/managed_artifact_storage_adapter.dart';
import 'package:shiroha_quiz/services/file_library/managed_file_storage_adapter.dart';
import 'package:shiroha_quiz/services/parsed_artifacts/deterministic_parsed_artifact_generation_adapter.dart';
import 'package:shiroha_quiz/services/parsed_artifacts/parsed_artifact_lifecycle_service.dart';
import 'package:shiroha_quiz/services/retrieval/deterministic_source_chunker.dart';
import 'package:shiroha_quiz/services/retrieval/parsed_artifact_retrieval_source.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _hiddenFact = '今天的隐藏数字是 59271';
const _sourceSha256 =
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late LibraryFileRepository libraryRepository;
  late ParsedArtifactRepository artifactRepository;
  late ManagedFileStorageAdapter originalStorage;
  late RetrievalService retrievalService;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    tempDir = await Directory.systemTemp.createTemp('rag_lazy_');
    libraryRepository = LibraryFileRepository();
    artifactRepository = ParsedArtifactRepository();
    originalStorage = ManagedFileStorageAdapter(managedRoot: tempDir);
    final lifecycle = ParsedArtifactLifecycleService(
      libraryFileRepository: libraryRepository,
      artifactRepository: artifactRepository,
      artifactStorage: ManagedArtifactStorageAdapter(managedRoot: tempDir),
      generationPort: DeterministicParsedArtifactGenerationAdapter(
        managedFileStorage: originalStorage,
      ),
    );
    retrievalService = RetrievalService(
      scopeResolver: _FilesScope(),
      artifactSource: ParsedArtifactRetrievalSource(
        lifecycle: lifecycle,
        metadata: artifactRepository,
      ),
      index: SqliteRetrievalIndexRepository(),
      chunker: const DeterministicSourceChunker(),
    );
  });

  tearDown(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test(
      'first retrieve provisions revision 1 from managed TXT bytes and the '
      'second retrieve reuses the same generation', () async {
    await _ingestTxt(
      tempDir: tempDir,
      storage: originalStorage,
      libraryRepository: libraryRepository,
      fileId: 'file-1',
      displayName: 'hidden-number.txt',
      storageKey: 'library/file-1',
      content: _hiddenFact,
    );

    expect(await artifactRepository.findCurrentByFileId('file-1'), isNull);
    expect(await artifactRepository.readRevisionHead('file-1'), 0);

    final first = await retrievalService.retrieve(
      scope: RetrievalFilesScope(const ['file-1']),
      query: '59271',
    );

    expect(first.perFileIssues, isEmpty);
    expect(first.rankedHits, isNotEmpty);
    expect(first.rankedHits.first.fileId, 'file-1');
    expect(first.rankedHits.first.revision, 1);
    expect(first.rankedHits.first.content, contains('59271'));
    expect(first.frozenScopeSnapshot.files.single.revision, 1);
    final metadata = (await artifactRepository.findCurrentByFileId('file-1'))!;
    expect(metadata.revision, 1);
    expect(metadata.parserRoute, 'txt');
    expect(await artifactRepository.readRevisionHead('file-1'), 1);

    final second = await retrievalService.retrieve(
      scope: RetrievalFilesScope(const ['file-1']),
      query: '59271',
    );

    expect(second.rankedHits, isNotEmpty);
    expect(second.rankedHits.first.content, contains('59271'));
    final after = (await artifactRepository.findCurrentByFileId('file-1'))!;
    expect(after.artifactId, metadata.artifactId);
    expect(after.revision, 1);
    expect(await artifactRepository.readRevisionHead('file-1'), 1);
  });

  test('agent path without approval never provisions body retrieval', () async {
    await _ingestTxt(
      tempDir: tempDir,
      storage: originalStorage,
      libraryRepository: libraryRepository,
      fileId: 'file-1',
      displayName: 'hidden-number.txt',
      storageKey: 'library/file-1',
      content: _hiddenFact,
    );
    final dispatcher = AgentRetrievalToolDispatcher(
      retrieval: retrievalService,
    );

    final output = await dispatcher.dispatch(
      argumentsJson: jsonEncode({
        'query': '59271',
        'file_ids': ['file-1'],
      }),
      grant: null,
      turnRequestId: 'turn-1',
      conversationId: 'conversation-1',
      sourceUserMessageId: 'message-1',
      providerProfileId: 'profile-1',
      currentFileIds: ['file-1'],
      serializationAllowed: () async => true,
    );

    expect(jsonDecode(output)['error']['code'], 'access_denied');
    expect(await artifactRepository.findCurrentByFileId('file-1'), isNull);
    expect(await artifactRepository.readRevisionHead('file-1'), 0);
    expect(await _indexBuildCount(), 0);
  });

  test('unsupported scanned source is never silently OCRed or fabricated',
      () async {
    await _ingestBytes(
      tempDir: tempDir,
      storage: originalStorage,
      libraryRepository: libraryRepository,
      fileId: 'file-2',
      displayName: 'scan.png',
      mimeType: 'image/png',
      storageKey: 'library/file-2',
      bytes: <int>[137, 80, 78, 71, 13, 10, 26, 10],
    );

    final result = await retrievalService.retrieve(
      scope: RetrievalFilesScope(const ['file-2']),
      query: 'hidden',
    );

    expect(result.rankedHits, isEmpty);
    expect(result.perFileIssues, hasLength(1));
    expect(result.perFileIssues.single.fileId, 'file-2');
    expect(await artifactRepository.findCurrentByFileId('file-2'), isNull);
    expect(await artifactRepository.readRevisionHead('file-2'), 0);
    expect(await _indexBuildCount(), 0);
  });

  test('artifactCorrupt stays a hard per-file issue and is never auto-repaired',
      () async {
    await _ingestTxt(
      tempDir: tempDir,
      storage: originalStorage,
      libraryRepository: libraryRepository,
      fileId: 'file-1',
      displayName: 'hidden-number.txt',
      storageKey: 'library/file-1',
      content: _hiddenFact,
    );
    final first = await retrievalService.retrieve(
      scope: RetrievalFilesScope(const ['file-1']),
      query: '59271',
    );
    expect(first.rankedHits, isNotEmpty);
    final metadata = (await artifactRepository.findCurrentByFileId('file-1'))!;
    final sidecar = File(p.join(tempDir.path, metadata.storageKey));
    await sidecar.writeAsBytes(utf8.encode('corrupted sidecar bytes'));

    final result = await retrievalService.retrieve(
      scope: RetrievalFilesScope(const ['file-1']),
      query: '59271',
    );

    expect(result.rankedHits, isEmpty);
    expect(result.perFileIssues.single.code,
        RetrievalFileIssueCode.artifactCorrupt);
    expect(
        (await artifactRepository.findCurrentByFileId('file-1'))!.revision, 1);
    expect(await artifactRepository.readRevisionHead('file-1'), 1);
  });
}

Future<void> _ingestTxt({
  required Directory tempDir,
  required ManagedFileStorageAdapter storage,
  required LibraryFileRepository libraryRepository,
  required String fileId,
  required String displayName,
  required String storageKey,
  required String content,
}) {
  return _ingestBytes(
    tempDir: tempDir,
    storage: storage,
    libraryRepository: libraryRepository,
    fileId: fileId,
    displayName: displayName,
    mimeType: 'text/plain',
    storageKey: storageKey,
    bytes: utf8.encode(content),
  );
}

Future<void> _ingestBytes({
  required Directory tempDir,
  required ManagedFileStorageAdapter storage,
  required LibraryFileRepository libraryRepository,
  required String fileId,
  required String displayName,
  required String mimeType,
  required String storageKey,
  required List<int> bytes,
}) async {
  final fixture = File(p.join(tempDir.path, displayName));
  await fixture.writeAsBytes(bytes);
  await storage.copyIntoManagedStorage(
    externalPath: fixture.path,
    storageKey: storageKey,
  );
  await fixture.delete();
  await libraryRepository.save(
    LibraryFile(
      fileId: fileId,
      displayName: displayName,
      mimeType: mimeType,
      sizeBytes: bytes.length,
      sha256: _sourceSha256,
      storageKey: storageKey,
      createdAt: DateTime.utc(2026, 8, 14),
    ),
  );
}

Future<int> _indexBuildCount() async {
  final db = await DatabaseHelper.instance.database;
  final rows = await db.rawQuery('SELECT count(*) AS count '
      'FROM retrieval_index_builds');
  return rows.single['count']! as int;
}

final class _FilesScope implements RetrievalScopeResolverPort {
  @override
  Future<List<String>> resolveFileIds(RetrievalScopeRequest scope) async {
    return switch (scope) {
      RetrievalFilesScope(:final fileIds) => fileIds,
      _ => const <String>[],
    };
  }
}
