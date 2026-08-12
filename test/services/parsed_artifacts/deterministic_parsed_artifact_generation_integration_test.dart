import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/application/parsed_artifacts/parsed_artifact_lifecycle.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/repositories/library_file_repository.dart';
import 'package:shiroha_quiz/data/repositories/parsed_artifact_repository.dart';
import 'package:shiroha_quiz/domain/assets/library_file.dart';
import 'package:shiroha_quiz/services/file_library/managed_artifact_storage_adapter.dart';
import 'package:shiroha_quiz/services/file_library/managed_file_storage_adapter.dart';
import 'package:shiroha_quiz/services/parsed_artifacts/deterministic_parsed_artifact_generation_adapter.dart';
import 'package:shiroha_quiz/services/parsed_artifacts/parsed_artifact_lifecycle_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _sha256 =
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late LibraryFileRepository libraryRepository;
  late ParsedArtifactRepository artifactRepository;
  late ManagedFileStorageAdapter originalStorage;
  late ManagedArtifactStorageAdapter artifactStorage;
  late ParsedArtifactLifecycleService service;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    tempDir = await Directory.systemTemp.createTemp('i1_integration_');
    libraryRepository = LibraryFileRepository();
    artifactRepository = ParsedArtifactRepository();
    originalStorage = ManagedFileStorageAdapter(managedRoot: tempDir);
    artifactStorage = ManagedArtifactStorageAdapter(managedRoot: tempDir);
    final generation = DeterministicParsedArtifactGenerationAdapter(
      managedFileStorage: originalStorage,
    );
    service = ParsedArtifactLifecycleService(
      libraryFileRepository: libraryRepository,
      artifactRepository: artifactRepository,
      artifactStorage: artifactStorage,
      generationPort: generation,
    );
  });

  tearDown(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('TXT ensure -> publish -> getCurrent -> cacheHit end to end', () async {
    final bytes = utf8.encode('first paragraph\n\nsecond paragraph');
    final fixture = File(p.join(tempDir.path, 'source_fixture.txt'));
    await fixture.writeAsBytes(bytes);
    await originalStorage.copyIntoManagedStorage(
      externalPath: fixture.path,
      storageKey: 'library/file-1',
    );
    await fixture.delete();
    await libraryRepository.save(
      LibraryFile(
        fileId: 'file-1',
        displayName: 'notes.txt',
        mimeType: 'text/plain',
        sizeBytes: bytes.length,
        sha256: _sha256,
        storageKey: 'library/file-1',
        createdAt: DateTime.utc(2026, 8, 13),
      ),
    );

    final first = await service.ensureParsedArtifact(
      fileId: 'file-1',
      options: const ParsedArtifactParseOptions(
        routeSelection: ParsedArtifactRouteSelection.auto,
      ),
    );

    expect(first.outcome, ParsedArtifactLifecycleOutcome.published);
    expect(first.snapshot.artifact.revision, 1);
    expect(first.snapshot.artifact.artifactId, isNot('file-1'));
    final metadata = (await artifactRepository.findCurrentByFileId('file-1'))!;
    expect(metadata.parserRoute, 'txt');
    expect(metadata.cacheKeyVersion, 1);

    final current = await service.getCurrentArtifact('file-1');
    expect(current.artifact, first.snapshot.artifact);
    expect(current.sourceDocument.documentRef.sourceId,
        first.snapshot.artifact.artifactId);

    final second = await service.ensureParsedArtifact(
      fileId: 'file-1',
      options: const ParsedArtifactParseOptions(
        routeSelection: ParsedArtifactRouteSelection.auto,
      ),
    );
    expect(second.outcome, ParsedArtifactLifecycleOutcome.cacheHit);
    expect(second.snapshot.artifact, first.snapshot.artifact);
    expect(await artifactRepository.readRevisionHead('file-1'), 1);
  });
}
