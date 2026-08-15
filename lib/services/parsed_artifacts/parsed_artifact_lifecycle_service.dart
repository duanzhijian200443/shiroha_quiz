// ignore_for_file: depend_on_referenced_packages
// `crypto` and `uuid` are existing dependencies of this package and the
// pubspec is frozen for this stage; no new direct dependency is introduced.
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import '../../application/file_library/file_library_ports.dart';
import '../../application/parsed_artifacts/parsed_artifact_lifecycle.dart';
import '../../application/parsed_artifacts/parsed_artifact_ports.dart';
import '../../domain/assets/library_file.dart';
import '../../domain/assets/parsed_artifact.dart';
import '../../domain/source/parsed_artifact_payload_codec.dart';
import '../../domain/source/source_document.dart';
import '../../services/file_library/managed_artifact_storage.dart';

const _resolvedParserRoutes = <String>{
  'pdf_text',
  'docx_text',
  'txt',
  'markdown',
  'ocr_pdf',
  'ocr_image',
};

const _cacheKeyVersion = 1;

/// Computes the cacheKeyVersion=1 opaque cache identity.
///
/// Semantic inputs are exactly: source SHA-256, payload schema version,
/// resolved parser route, parser version, and options schema version. The
/// serialization is deterministic and unambiguous (length-prefixed UTF-8);
/// the concrete hash algorithm is an implementation detail, not a canonical
/// architecture rule.
ParsedArtifactCacheKey computeParsedArtifactCacheKeyV1({
  required String sourceSha256,
  required int payloadSchemaVersion,
  required String parserRoute,
  required String parserVersion,
  required int optionsSchemaVersion,
}) {
  final buffer = BytesBuilder();
  void writeInt(int value) {
    buffer.add(<int>[
      (value >> 24) & 0xff,
      (value >> 16) & 0xff,
      (value >> 8) & 0xff,
      value & 0xff,
    ]);
  }

  void writeString(String value) {
    final bytes = utf8.encode(value);
    writeInt(bytes.length);
    buffer.add(bytes);
  }

  writeInt(_cacheKeyVersion);
  writeString(sourceSha256);
  writeInt(payloadSchemaVersion);
  writeString(parserRoute);
  writeString(parserVersion);
  writeInt(optionsSchemaVersion);
  final fingerprint = sha256.convert(buffer.toBytes()).toString();
  return ParsedArtifactCacheKey(
    version: _cacheKeyVersion,
    fingerprint: fingerprint,
  );
}

final _fileIdPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');

/// A1 lifecycle orchestration over the frozen D1 persistence/storage
/// primitives.
///
/// All mutations for one fileId are serialized through a process-wide future
/// chain keyed by the safe fileId (single-process model; no cross-process
/// lock; never exposed to Application consumers). Reads do not hold the
/// mutation gate, so an in-flight reparse never blocks `getCurrentArtifact`.
final class ParsedArtifactLifecycleService
    implements ParsedArtifactLifecyclePort {
  ParsedArtifactLifecycleService({
    required LibraryFileRepositoryPort libraryFileRepository,
    required ParsedArtifactRepositoryPort artifactRepository,
    required ManagedArtifactStorage artifactStorage,
    required ParsedArtifactGenerationPort generationPort,
  })  : _libraryFileRepository = libraryFileRepository,
        _artifactRepository = artifactRepository,
        _artifactStorage = artifactStorage,
        _generationPort = generationPort;

  final LibraryFileRepositoryPort _libraryFileRepository;
  final ParsedArtifactRepositoryPort _artifactRepository;
  final ManagedArtifactStorage _artifactStorage;
  final ParsedArtifactGenerationPort _generationPort;

  static const ParsedArtifactPayloadCodec _payloadCodec =
      ParsedArtifactPayloadCodec();
  static const Uuid _uuid = Uuid();

  /// Process-wide per-file mutation chains. Completed tails are removed so
  /// the map never leaks entries and a previous failure never poisons the
  /// chain.
  static final Map<String, Future<void>> _mutationChains =
      <String, Future<void>>{};

  @override
  Future<ParsedArtifactSnapshot> getCurrentArtifact(String fileId) async {
    try {
      _validateFileId(fileId);
      await _requireLibraryFile(fileId);
      final (metadata, sourceDocument) = await _loadVerifiedCurrent(fileId);
      return _snapshotFrom(metadata, sourceDocument);
    } on ParsedArtifactLifecycleException {
      rethrow;
    } catch (_) {
      throw const ParsedArtifactLifecycleException(
        ParsedArtifactLifecycleFailure.internalError,
      );
    }
  }

  @override
  Future<ParsedArtifactEnsureResult> ensureParsedArtifact({
    required String fileId,
    required ParsedArtifactParseOptions options,
  }) async {
    try {
      _validateFileId(fileId);
      return await _runFileMutationExclusive(fileId, () async {
        final file = await _requireLibraryFile(fileId);
        final plan = await _resolvePlan(file, options);
        final cacheKey = _computeCacheKey(file, plan);
        final current = await _artifactRepository.findCurrentByFileId(fileId);
        if (current != null) {
          final (verified, verifiedSource) = await _loadVerifiedCurrent(fileId);
          if (_matchesCacheFacts(verified, file, plan, cacheKey)) {
            return ParsedArtifactEnsureResult(
              outcome: ParsedArtifactLifecycleOutcome.cacheHit,
              snapshot: _snapshotFrom(verified, verifiedSource),
            );
          }
        }
        final head = await _artifactRepository.readRevisionHead(fileId);
        final snapshot = await _publishNewGeneration(
          file: file,
          plan: plan,
          cacheKey: cacheKey,
          expectedRevision: head,
          previousStorageKey: current?.storageKey,
        );
        return ParsedArtifactEnsureResult(
          outcome: ParsedArtifactLifecycleOutcome.published,
          snapshot: snapshot,
        );
      });
    } on ParsedArtifactLifecycleException {
      rethrow;
    } catch (_) {
      throw const ParsedArtifactLifecycleException(
        ParsedArtifactLifecycleFailure.internalError,
      );
    }
  }

  @override
  Future<ParsedArtifactEnsureResult> reparseArtifact({
    required String fileId,
    required ParsedArtifactParseOptions options,
    required int expectedRevision,
  }) async {
    try {
      _validateFileId(fileId);
      return await _runFileMutationExclusive(fileId, () async {
        final file = await _requireLibraryFile(fileId);
        final head = await _artifactRepository.readRevisionHead(fileId);
        if (expectedRevision != head) {
          throw const ParsedArtifactLifecycleException(
            ParsedArtifactLifecycleFailure.publishConflict,
          );
        }
        final plan = await _resolvePlan(file, options);
        final cacheKey = _computeCacheKey(file, plan);
        final current = await _artifactRepository.findCurrentByFileId(fileId);
        final snapshot = await _publishNewGeneration(
          file: file,
          plan: plan,
          cacheKey: cacheKey,
          expectedRevision: head,
          previousStorageKey: current?.storageKey,
        );
        return ParsedArtifactEnsureResult(
          outcome: ParsedArtifactLifecycleOutcome.published,
          snapshot: snapshot,
        );
      });
    } on ParsedArtifactLifecycleException {
      rethrow;
    } catch (_) {
      throw const ParsedArtifactLifecycleException(
        ParsedArtifactLifecycleFailure.internalError,
      );
    }
  }

  @override
  Future<void> removeCurrentArtifact({
    required String fileId,
    required int expectedRevision,
  }) async {
    try {
      _validateFileId(fileId);
      if (expectedRevision < 0) {
        throw const ParsedArtifactLifecycleException(
          ParsedArtifactLifecycleFailure.invalidRequest,
        );
      }
      await _runFileMutationExclusive(fileId, () async {
        await _requireLibraryFile(fileId);
        final current = await _artifactRepository.findCurrentByFileId(fileId);
        if (current == null) {
          throw const ParsedArtifactLifecycleException(
            ParsedArtifactLifecycleFailure.artifactMissing,
          );
        }
        final storageKey = current.storageKey;
        final result = await _artifactRepository.removeCurrent(
          fileId: fileId,
          expectedRevision: expectedRevision,
        );
        switch (result.status) {
          case ParsedArtifactRemoveStatus.removed:
            break;
          case ParsedArtifactRemoveStatus.notFound:
            throw const ParsedArtifactLifecycleException(
              ParsedArtifactLifecycleFailure.artifactMissing,
            );
          case ParsedArtifactRemoveStatus.revisionConflict:
            throw const ParsedArtifactLifecycleException(
              ParsedArtifactLifecycleFailure.publishConflict,
            );
        }
        await _bestEffortDeleteSidecar(storageKey);
      });
    } on ParsedArtifactLifecycleException {
      rethrow;
    } catch (_) {
      throw const ParsedArtifactLifecycleException(
        ParsedArtifactLifecycleFailure.internalError,
      );
    }
  }

  /// Loads current metadata and verifies the immutable sidecar and payload.
  ///
  /// A missing sidecar triggers one metadata re-read to tolerate the legal
  /// replacement race (reader saw old metadata, writer committed a new
  /// generation and cleaned the old sidecar); the retry runs against the
  /// latest current generation and never loops unbounded.
  Future<(ParsedArtifactMetadata, SourceDocument)> _loadVerifiedCurrent(
    String fileId,
  ) async {
    final fetched = await _artifactRepository.findCurrentByFileId(fileId);
    if (fetched == null) {
      throw const ParsedArtifactLifecycleException(
        ParsedArtifactLifecycleFailure.artifactMissing,
      );
    }
    var metadata = fetched;
    var attempts = 0;
    while (true) {
      attempts++;
      final sourceDocument = await _readVerifiedSidecar(metadata);
      if (sourceDocument != null) {
        return (metadata, sourceDocument);
      }
      // The sidecar for the currently observed generation is missing.
      // Re-read the current metadata to distinguish the legal replacement
      // race from stable corruption.
      final latest = await _artifactRepository.findCurrentByFileId(fileId);
      if (latest == null) {
        // The current was removed while reading; a missing artifact is legal.
        throw const ParsedArtifactLifecycleException(
          ParsedArtifactLifecycleFailure.artifactMissing,
        );
      }
      if (latest.artifactId == metadata.artifactId &&
          latest.revision == metadata.revision) {
        // The current generation still points at a missing sidecar: stable
        // corruption, not a replacement race.
        throw const ParsedArtifactLifecycleException(
          ParsedArtifactLifecycleFailure.artifactCorrupt,
        );
      }
      if (attempts >= 2) {
        // The generation kept changing across the bounded retry window, so
        // the current artifact cannot be stably observed. Report a safe
        // transient failure instead of misreporting stable artifactMissing
        // or artifactCorrupt.
        throw const ParsedArtifactLifecycleException(
          ParsedArtifactLifecycleFailure.temporarilyUnavailable,
        );
      }
      metadata = latest;
    }
  }

  /// Returns the decoded [SourceDocument] when the sidecar exists, passes
  /// size/digest checks, strictly decodes, and binds to the same
  /// fileId/artifactId. Returns null when the sidecar is absent
  /// (replacement race).
  Future<SourceDocument?> _readVerifiedSidecar(
    ParsedArtifactMetadata metadata,
  ) async {
    if (metadata.payloadSchemaVersion !=
        ParsedArtifactPayloadCodec.schemaVersion) {
      throw const ParsedArtifactLifecycleException(
        ParsedArtifactLifecycleFailure.payloadUnsupported,
      );
    }
    try {
      final read = await _artifactStorage.readArtifact(
        storageKey: metadata.storageKey,
        expectedSha256: metadata.payloadSha256,
        expectedSizeBytes: metadata.sizeBytes,
      );
      if (read == null) return null;
      final text = utf8.decode(read.bytes, allowMalformed: false);
      final json = jsonDecode(text);
      final payload = _payloadCodec.decode(json);
      if (payload.fileId != metadata.fileId ||
          payload.artifactId != metadata.artifactId) {
        throw const ParsedArtifactLifecycleException(
          ParsedArtifactLifecycleFailure.artifactCorrupt,
        );
      }
      return payload.sourceDocument;
    } on ParsedArtifactLifecycleException {
      rethrow;
    } on ManagedArtifactStorageException catch (error) {
      throw _storageFailure(error);
    } on UnsupportedError {
      throw const ParsedArtifactLifecycleException(
        ParsedArtifactLifecycleFailure.payloadUnsupported,
      );
    } catch (_) {
      throw const ParsedArtifactLifecycleException(
        ParsedArtifactLifecycleFailure.artifactCorrupt,
      );
    }
  }

  ParsedArtifactCacheKey _computeCacheKey(
    LibraryFile file,
    ParsedArtifactGenerationPlan plan,
  ) {
    return computeParsedArtifactCacheKeyV1(
      sourceSha256: file.sha256,
      payloadSchemaVersion: ParsedArtifactPayloadCodec.schemaVersion,
      parserRoute: plan.parserRoute,
      parserVersion: plan.parserVersion,
      optionsSchemaVersion: plan.optionsSchemaVersion,
    );
  }

  bool _matchesCacheFacts(
    ParsedArtifactMetadata metadata,
    LibraryFile file,
    ParsedArtifactGenerationPlan plan,
    ParsedArtifactCacheKey cacheKey,
  ) {
    return metadata.sourceSha256 == file.sha256 &&
        metadata.cacheKeyVersion == cacheKey.version &&
        metadata.cacheFingerprint == cacheKey.fingerprint &&
        metadata.parserRoute == plan.parserRoute &&
        metadata.parserVersion == plan.parserVersion &&
        metadata.optionsSchemaVersion == plan.optionsSchemaVersion &&
        metadata.payloadSchemaVersion ==
            ParsedArtifactPayloadCodec.schemaVersion;
  }

  Future<ParsedArtifactSnapshot> _publishNewGeneration({
    required LibraryFile file,
    required ParsedArtifactGenerationPlan plan,
    required ParsedArtifactCacheKey cacheKey,
    required int expectedRevision,
    required String? previousStorageKey,
  }) async {
    final artifactId = _uuid.v4();
    final candidateRevision = expectedRevision + 1;
    final sourceDocument = await _generate(file, artifactId, plan);
    final payload = ParsedArtifactPayload(
      schemaVersion: ParsedArtifactPayloadCodec.schemaVersion,
      artifactId: artifactId,
      fileId: file.fileId,
      sourceDocument: sourceDocument,
    );
    final bytes = utf8.encode(jsonEncode(_payloadCodec.encode(payload)));
    final ArtifactWriteResult writeResult;
    final String storageKey;
    try {
      storageKey = _artifactStorage.allocateArtifactStorageKey(artifactId);
      writeResult = await _artifactStorage.writeArtifact(
        storageKey: storageKey,
        bytes: bytes,
      );
    } on ManagedArtifactStorageException catch (error) {
      throw _storageFailure(error);
    }
    final metadata = ParsedArtifactMetadata(
      artifact: ParsedArtifact(
        fileId: file.fileId,
        artifactId: artifactId,
        revision: candidateRevision,
        payloadSchemaVersion: payload.schemaVersion,
      ),
      sourceSha256: file.sha256,
      cacheKeyVersion: cacheKey.version,
      cacheFingerprint: cacheKey.fingerprint,
      parserRoute: plan.parserRoute,
      parserVersion: plan.parserVersion,
      optionsSchemaVersion: plan.optionsSchemaVersion,
      storageKey: storageKey,
      payloadSha256: writeResult.sha256,
      sizeBytes: writeResult.sizeBytes,
      publishedAt: DateTime.now().millisecondsSinceEpoch,
    );

    final ParsedArtifactPublishResult publishResult;
    try {
      publishResult = await _artifactRepository.publishCurrent(
        fileId: file.fileId,
        candidate: metadata,
        expectedRevision: expectedRevision,
      );
    } on ParsedArtifactRepositoryException catch (error) {
      await _bestEffortDeleteSidecar(storageKey);
      throw _repositoryFailure(error);
    }

    switch (publishResult.status) {
      case ParsedArtifactPublishStatus.published:
        if (previousStorageKey != null) {
          await _bestEffortDeleteSidecar(previousStorageKey);
        }
        return _snapshotFrom(metadata, sourceDocument);
      case ParsedArtifactPublishStatus.parentMissing:
        await _bestEffortDeleteSidecar(storageKey);
        throw const ParsedArtifactLifecycleException(
          ParsedArtifactLifecycleFailure.fileNotFound,
        );
      case ParsedArtifactPublishStatus.revisionConflict:
        await _bestEffortDeleteSidecar(storageKey);
        throw const ParsedArtifactLifecycleException(
          ParsedArtifactLifecycleFailure.publishConflict,
        );
    }
  }

  Future<ParsedArtifactGenerationPlan> _resolvePlan(
    LibraryFile file,
    ParsedArtifactParseOptions options,
  ) async {
    final ParsedArtifactGenerationPlan plan;
    try {
      plan = await _generationPort.resolvePlan(
        file: file,
        options: options,
      );
    } on ParsedArtifactGenerationException catch (error) {
      throw _generationFailure(error);
    } catch (_) {
      throw const ParsedArtifactLifecycleException(
        ParsedArtifactLifecycleFailure.internalError,
      );
    }

    if (!_resolvedParserRoutes.contains(plan.parserRoute)) {
      throw const ParsedArtifactLifecycleException(
        ParsedArtifactLifecycleFailure.internalError,
      );
    }
    final explicitRoute = _routeForSelection(options.routeSelection);
    if (explicitRoute != null && explicitRoute != plan.parserRoute) {
      throw const ParsedArtifactLifecycleException(
        ParsedArtifactLifecycleFailure.internalError,
      );
    }
    if (options.routeSelection == ParsedArtifactRouteSelection.auto &&
        plan.parserRoute.startsWith('ocr_')) {
      throw const ParsedArtifactLifecycleException(
        ParsedArtifactLifecycleFailure.internalError,
      );
    }
    return plan;
  }

  Future<SourceDocument> _generate(
    LibraryFile file,
    String artifactId,
    ParsedArtifactGenerationPlan plan,
  ) async {
    final SourceDocument sourceDocument;
    try {
      sourceDocument = await _generationPort.generate(
        file: file,
        artifactId: artifactId,
        plan: plan,
      );
    } on ParsedArtifactGenerationException catch (error) {
      throw _generationFailure(error);
    } catch (_) {
      throw const ParsedArtifactLifecycleException(
        ParsedArtifactLifecycleFailure.internalError,
      );
    }
    if (sourceDocument.documentRef.sourceId != artifactId) {
      throw const ParsedArtifactLifecycleException(
        ParsedArtifactLifecycleFailure.internalError,
      );
    }
    return sourceDocument;
  }

  Future<LibraryFile> _requireLibraryFile(String fileId) async {
    final file = await _libraryFileRepository.findById(fileId);
    if (file == null) {
      throw const ParsedArtifactLifecycleException(
        ParsedArtifactLifecycleFailure.fileNotFound,
      );
    }
    return file;
  }

  ParsedArtifactSnapshot _snapshotFrom(
    ParsedArtifactMetadata metadata,
    SourceDocument sourceDocument,
  ) {
    return ParsedArtifactSnapshot(
      artifact: metadata.artifact,
      sourceDocument: sourceDocument,
      parserRoute: metadata.parserRoute,
    );
  }

  Future<void> _bestEffortDeleteSidecar(String storageKey) async {
    try {
      await _artifactStorage.deleteArtifact(storageKey);
    } catch (_) {
      // Best-effort cleanup: a leftover sidecar is an orphan and never
      // changes the already-determined primary outcome.
    }
  }

  ParsedArtifactLifecycleException _storageFailure(
    ManagedArtifactStorageException error,
  ) {
    return switch (error.failure) {
      ManagedArtifactStorageFailure.sizeMismatch ||
      ManagedArtifactStorageFailure.digestMismatch =>
        const ParsedArtifactLifecycleException(
          ParsedArtifactLifecycleFailure.artifactCorrupt,
        ),
      ManagedArtifactStorageFailure.ioFailed =>
        const ParsedArtifactLifecycleException(
          ParsedArtifactLifecycleFailure.temporarilyUnavailable,
        ),
      ManagedArtifactStorageFailure.unsafeArtifactId ||
      ManagedArtifactStorageFailure.unsafeStorageKey ||
      ManagedArtifactStorageFailure.alreadyFinalized =>
        const ParsedArtifactLifecycleException(
          ParsedArtifactLifecycleFailure.internalError,
        ),
    };
  }

  ParsedArtifactLifecycleException _repositoryFailure(
    ParsedArtifactRepositoryException error,
  ) {
    return switch (error.failure) {
      ParsedArtifactRepositoryFailure.invalidRequest =>
        const ParsedArtifactLifecycleException(
          ParsedArtifactLifecycleFailure.invalidRequest,
        ),
      ParsedArtifactRepositoryFailure.duplicateIdentity =>
        const ParsedArtifactLifecycleException(
          ParsedArtifactLifecycleFailure.internalError,
        ),
      ParsedArtifactRepositoryFailure.unavailable =>
        const ParsedArtifactLifecycleException(
          ParsedArtifactLifecycleFailure.temporarilyUnavailable,
        ),
    };
  }

  ParsedArtifactLifecycleException _generationFailure(
    ParsedArtifactGenerationException error,
  ) {
    return switch (error.failure) {
      ParsedArtifactGenerationFailure.unsupportedRoute =>
        const ParsedArtifactLifecycleException(
          ParsedArtifactLifecycleFailure.unsupportedRoute,
        ),
      ParsedArtifactGenerationFailure.sourceUnavailable =>
        const ParsedArtifactLifecycleException(
          ParsedArtifactLifecycleFailure.sourceUnavailable,
        ),
      ParsedArtifactGenerationFailure.parseFailed =>
        const ParsedArtifactLifecycleException(
          ParsedArtifactLifecycleFailure.parseFailed,
        ),
      ParsedArtifactGenerationFailure.temporarilyUnavailable =>
        const ParsedArtifactLifecycleException(
          ParsedArtifactLifecycleFailure.temporarilyUnavailable,
        ),
    };
  }

  Future<T> _runFileMutationExclusive<T>(
    String fileId,
    Future<T> Function() action,
  ) {
    final previous = _mutationChains[fileId] ?? Future<void>.value();
    final result = previous.then((_) => action());
    final tail = result.then<void>((_) {}, onError: (Object _) {});
    _mutationChains[fileId] = tail;
    tail.whenComplete(() {
      if (identical(_mutationChains[fileId], tail)) {
        _mutationChains.remove(fileId);
      }
    });
    return result;
  }
}

String? _routeForSelection(ParsedArtifactRouteSelection selection) {
  return switch (selection) {
    ParsedArtifactRouteSelection.auto => null,
    ParsedArtifactRouteSelection.pdfText => 'pdf_text',
    ParsedArtifactRouteSelection.docxText => 'docx_text',
    ParsedArtifactRouteSelection.txt => 'txt',
    ParsedArtifactRouteSelection.markdown => 'markdown',
    ParsedArtifactRouteSelection.ocrPdf => 'ocr_pdf',
    ParsedArtifactRouteSelection.ocrImage => 'ocr_image',
  };
}

void _validateFileId(String fileId) {
  if (!_fileIdPattern.hasMatch(fileId)) {
    throw const ParsedArtifactLifecycleException(
      ParsedArtifactLifecycleFailure.invalidRequest,
    );
  }
}
