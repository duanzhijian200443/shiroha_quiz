// One synthetic file on the SAME App database as the TLS/Proposal authority.
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/application/external/external_file_read.dart';
import 'package:shiroha_quiz/application/parsed_artifacts/parsed_artifact_lifecycle.dart';
import 'package:shiroha_quiz/data/repositories/content_asset_reclamation_observation_repository.dart';
import 'package:shiroha_quiz/data/repositories/external_file_read_repository.dart';
import 'package:shiroha_quiz/data/repositories/library_file_repository.dart';
import 'package:shiroha_quiz/data/repositories/parsed_artifact_repository.dart';
import 'package:shiroha_quiz/data/repositories/retrieval_index_repository.dart';
import 'package:shiroha_quiz/domain/assets/library_file.dart';
import 'package:shiroha_quiz/services/file_library/managed_artifact_storage_adapter.dart';
import 'package:shiroha_quiz/services/parsed_artifacts/parsed_artifact_lifecycle_service.dart';
import 'package:shiroha_quiz/services/retrieval/deterministic_source_chunker.dart';
import '../../application/external/external_file_read_test_support.dart'
    show FileGeneration, FileIndexBarrier, ObservedF1;
import '../../application/external/external_trust_test_support.dart';

final class VnextTlsFileFixture {
  VnextTlsFileFixture(this.app);
  final OfflineTrustHarness app;
  Future<ExternalFileReader>? _reader;
  late FileIndexBarrier index;
  late ObservedF1 source;
  static const fileId = 'v3-file';
  Future<ExternalFileReader> reader() => _reader ??= _open();
  Future<ExternalFileReader> _open() async {
    final helper = app.local.h.helper;
    final managed = Directory(p.join(app.local.h.temp.path, 'v3-managed'));
    final original = File(p.join(managed.path, 'library', fileId));
    await original.parent.create(recursive: true);
    await original.writeAsString('abc');
    final files = LibraryFileRepository(databaseHelper: helper);
    await files.save(LibraryFile(
        fileId: fileId,
        displayName: 'Synthetic.txt',
        mimeType: 'text/plain',
        sizeBytes: 3,
        sha256:
            'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
        storageKey: 'library/$fileId',
        createdAt: DateTime.utc(2026)));
    final metadata = ParsedArtifactRepository(databaseHelper: helper);
    final lifecycle = ParsedArtifactLifecycleService(
        libraryFileRepository: files,
        artifactRepository: metadata,
        artifactStorage: ManagedArtifactStorageAdapter(managedRoot: managed),
        generationPort: FileGeneration(),
        reclamationReset: ContentAssetReclamationObservationRepository(
            databaseHelper: helper));
    await lifecycle.ensureParsedArtifact(
        fileId: fileId,
        options: const ParsedArtifactParseOptions(
            routeSelection: ParsedArtifactRouteSelection.auto));
    source = ObservedF1(lifecycle);
    index = FileIndexBarrier(
        SqliteRetrievalIndexRepository(databaseHelper: helper));
    return ExternalFileReader(
        authorization: SqliteExternalFileReadRepository(databaseHelper: helper),
        source: ExternalVerifiedArtifactSource(
            lifecycle: source, metadata: metadata),
        index: index,
        chunker: const DeterministicSourceChunker());
  }
}
