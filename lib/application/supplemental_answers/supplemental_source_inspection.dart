import '../../domain/assets/library_file.dart';
import '../file_library/file_library_ports.dart';
import '../parsed_artifacts/parsed_artifact_lifecycle.dart';

/// Safe failure categories for one transient original-source inspection.
enum SupplementalSourceInspectionFailure {
  fileUnavailable,
  artifactUnavailable,
  artifactChanged,
  sourceIntegrityMismatch,
  resourceLimitExceeded,
  sourceReadFailed,
}

/// Fixed safe failure that never retains a path, key, cause, or file content.
final class SupplementalSourceInspectionException implements Exception {
  const SupplementalSourceInspectionException(this.failure);

  final SupplementalSourceInspectionFailure failure;

  @override
  String toString() {
    final detail = switch (failure) {
      SupplementalSourceInspectionFailure.fileUnavailable =>
        'The source file is unavailable.',
      SupplementalSourceInspectionFailure.artifactUnavailable =>
        'The current parsed artifact is unavailable.',
      SupplementalSourceInspectionFailure.artifactChanged =>
        'The parsed artifact changed during source inspection.',
      SupplementalSourceInspectionFailure.sourceIntegrityMismatch =>
        'The managed source bytes do not match current file metadata.',
      SupplementalSourceInspectionFailure.resourceLimitExceeded =>
        'The source exceeds the configured read budget.',
      SupplementalSourceInspectionFailure.sourceReadFailed =>
        'The managed source could not be read.',
    };
    return 'SupplementalSourceInspectionException(${failure.name}): $detail';
  }
}

/// Safe classifications a managed-byte reader may report to the service.
enum SupplementalSourceReaderFailure {
  fileUnavailable,
  resourceLimitExceeded,
  sourceReadFailed,
}

/// Fixed safe reader failure; physical read details are deliberately dropped.
final class SupplementalSourceReaderException implements Exception {
  const SupplementalSourceReaderException(this.failure);

  final SupplementalSourceReaderFailure failure;

  @override
  String toString() => 'SupplementalSourceReaderException.';
}

/// One bounded read of a managed original file.
///
/// This is an Application/infrastructure handoff value, not a UI result.
final class SupplementalSourceReadResult {
  SupplementalSourceReadResult({
    required List<int> bytes,
    required this.actualSizeBytes,
    required this.actualSha256,
  }) : bytes = List<int>.unmodifiable(bytes);

  final List<int> bytes;
  final int actualSizeBytes;
  final String actualSha256;
}

/// Reads original bytes for an already resolved [LibraryFile].
///
/// Implementations read only managed original bytes. They do not parse,
/// project, OCR, or assess source fidelity.
abstract interface class SupplementalSourceReaderPort {
  Future<SupplementalSourceReadResult> readOriginalBytes({
    required LibraryFile file,
    required int maxBytes,
  });
}

/// Immutable, transient evidence tying original bytes to one artifact
/// generation. Only [SupplementalSourceInspectionService] can create one.
final class SupplementalSourceInspection {
  SupplementalSourceInspection._({
    required this.fileId,
    required this.artifactId,
    required this.artifactRevision,
    required this.displayName,
    required this.mimeType,
    required this.sizeBytes,
    required this.sha256,
    required List<int> originalBytes,
  }) : originalBytes = List<int>.unmodifiable(originalBytes);

  final String fileId;
  final String artifactId;
  final int artifactRevision;
  final String displayName;
  final String mimeType;
  final int sizeBytes;
  final String sha256;

  /// Exact original managed bytes, exposed as an immutable list.
  final List<int> originalBytes;
}

/// Creates a transient inspection only when file bytes and the current
/// ParsedArtifact generation remain stable across the bounded read.
///
/// This service does not parse, persist, mutate, mark user verification, or
/// make a source-fidelity judgment.
final class SupplementalSourceInspectionService {
  SupplementalSourceInspectionService({
    required LibraryFileRepositoryPort fileCatalog,
    required ParsedArtifactLifecyclePort artifactPort,
    required SupplementalSourceReaderPort sourceReader,
    required int maxBytes,
  })  : _fileCatalog = fileCatalog,
        _artifactPort = artifactPort,
        _sourceReader = sourceReader,
        _maxBytes = _validateMaxBytes(maxBytes);

  final LibraryFileRepositoryPort _fileCatalog;
  final ParsedArtifactLifecyclePort _artifactPort;
  final SupplementalSourceReaderPort _sourceReader;
  final int _maxBytes;

  /// Reads and verifies one file without creating durable or user-verification
  /// state.
  Future<SupplementalSourceInspection> inspect(String fileId) async {
    final fileBefore = await _findFile(fileId);
    if (fileBefore.sizeBytes > _maxBytes) {
      _fail(SupplementalSourceInspectionFailure.resourceLimitExceeded);
    }

    final artifactBefore = await _getCurrentArtifact(fileId);
    if (artifactBefore.artifact.fileId != fileId) {
      _fail(SupplementalSourceInspectionFailure.artifactUnavailable);
    }

    final read = await _readOriginalBytes(fileBefore);
    if (read.bytes.length != read.actualSizeBytes ||
        read.actualSizeBytes != fileBefore.sizeBytes ||
        read.actualSha256 != fileBefore.sha256) {
      _fail(SupplementalSourceInspectionFailure.sourceIntegrityMismatch);
    }

    final fileAfter = await _findFile(fileId);
    if (fileAfter != fileBefore) {
      _fail(SupplementalSourceInspectionFailure.sourceIntegrityMismatch);
    }

    final artifactAfter = await _getCurrentArtifact(fileId);
    if (artifactAfter.artifact.fileId != fileId ||
        artifactAfter.artifact.artifactId !=
            artifactBefore.artifact.artifactId ||
        artifactAfter.artifact.revision != artifactBefore.artifact.revision) {
      _fail(SupplementalSourceInspectionFailure.artifactChanged);
    }

    return SupplementalSourceInspection._(
      fileId: fileBefore.fileId,
      artifactId: artifactBefore.artifact.artifactId,
      artifactRevision: artifactBefore.artifact.revision,
      displayName: fileBefore.displayName,
      mimeType: fileBefore.mimeType,
      sizeBytes: read.actualSizeBytes,
      sha256: read.actualSha256,
      originalBytes: read.bytes,
    );
  }

  Future<LibraryFile> _findFile(String fileId) async {
    try {
      final file = await _fileCatalog.findById(fileId);
      if (file == null || file.fileId != fileId) {
        _fail(SupplementalSourceInspectionFailure.fileUnavailable);
      }
      return file;
    } on SupplementalSourceInspectionException {
      rethrow;
    } catch (_) {
      _fail(SupplementalSourceInspectionFailure.fileUnavailable);
    }
  }

  Future<ParsedArtifactSnapshot> _getCurrentArtifact(String fileId) async {
    try {
      return await _artifactPort.getCurrentArtifact(fileId);
    } catch (_) {
      _fail(SupplementalSourceInspectionFailure.artifactUnavailable);
    }
  }

  Future<SupplementalSourceReadResult> _readOriginalBytes(
    LibraryFile file,
  ) async {
    try {
      return await _sourceReader.readOriginalBytes(
        file: file,
        maxBytes: _maxBytes,
      );
    } on SupplementalSourceReaderException catch (error) {
      final failure = switch (error.failure) {
        SupplementalSourceReaderFailure.fileUnavailable =>
          SupplementalSourceInspectionFailure.fileUnavailable,
        SupplementalSourceReaderFailure.resourceLimitExceeded =>
          SupplementalSourceInspectionFailure.resourceLimitExceeded,
        SupplementalSourceReaderFailure.sourceReadFailed =>
          SupplementalSourceInspectionFailure.sourceReadFailed,
      };
      _fail(failure);
    } catch (_) {
      _fail(SupplementalSourceInspectionFailure.sourceReadFailed);
    }
  }

  Never _fail(SupplementalSourceInspectionFailure failure) {
    throw SupplementalSourceInspectionException(failure);
  }

  static int _validateMaxBytes(int maxBytes) {
    if (maxBytes < 0) {
      throw ArgumentError.value(maxBytes, 'maxBytes', 'Must be non-negative.');
    }
    return maxBytes;
  }
}
