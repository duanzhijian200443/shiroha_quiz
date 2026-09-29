import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/file_library/file_library_ports.dart';
import 'package:shiroha_quiz/application/parsed_artifacts/parsed_artifact_lifecycle.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_source_inspection.dart';
import 'package:shiroha_quiz/domain/assets/library_file.dart';
import 'package:shiroha_quiz/domain/assets/parsed_artifact.dart';
import 'package:shiroha_quiz/domain/source/source_document.dart';

const _abcSha256 =
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
const _storageKey = 'library/file-1';

void main() {
  group('SupplementalSourceInspectionService', () {
    test('binds verified immutable bytes to one stable generation', () async {
      final events = <String>[];
      final input = <int>[97, 98, 99];
      final file = _file();
      final catalog = _FileCatalog(<LibraryFile?>[file, file], events);
      final artifact = _ArtifactPort(
        <Object>[
          _snapshot(artifactId: 'artifact-1', revision: 3),
          _snapshot(artifactId: 'artifact-1', revision: 3)
        ],
        events,
      );
      final reader = _SourceReader(
        SupplementalSourceReadResult(
          bytes: input,
          actualSizeBytes: input.length,
          actualSha256: _abcSha256,
        ),
        events,
      );

      final inspection = await _service(
        catalog: catalog,
        artifact: artifact,
        reader: reader,
        maxBytes: 8,
      ).inspect('file-1');

      expect(inspection.fileId, 'file-1');
      expect(inspection.artifactId, 'artifact-1');
      expect(inspection.artifactRevision, 3);
      expect(inspection.displayName, 'source.pdf');
      expect(inspection.mimeType, 'application/pdf');
      expect(inspection.sizeBytes, 3);
      expect(inspection.sha256, _abcSha256);
      expect(inspection.originalBytes, <int>[97, 98, 99]);
      expect(
          events, <String>['file', 'artifact', 'reader', 'file', 'artifact']);
      expect(reader.lastMaxBytes, 8);
      expect(catalog.writeCalls, 0);
      expect(artifact.mutationCalls, 0);

      input[0] = 0;
      expect(inspection.originalBytes, <int>[97, 98, 99]);
      expect(
        () => inspection.originalBytes[0] = 0,
        throwsUnsupportedError,
      );
    });

    test('rejects an actual size that disagrees with LibraryFile metadata',
        () async {
      final failure = await _inspectFailure(
        catalogFiles: <LibraryFile?>[_file(), _file()],
        readResult: SupplementalSourceReadResult(
          bytes: <int>[97, 98],
          actualSizeBytes: 2,
          actualSha256: _abcSha256,
        ),
      );

      expect(
        failure.failure,
        SupplementalSourceInspectionFailure.sourceIntegrityMismatch,
      );
    });

    test('rejects an actual hash that disagrees with LibraryFile metadata',
        () async {
      final failure = await _inspectFailure(
        catalogFiles: <LibraryFile?>[_file(), _file()],
        readResult: SupplementalSourceReadResult(
          bytes: <int>[97, 98, 99],
          actualSizeBytes: 3,
          actualSha256: '0' * 64,
        ),
      );

      expect(
        failure.failure,
        SupplementalSourceInspectionFailure.sourceIntegrityMismatch,
      );
    });

    test('rejects metadata over budget before reading bytes', () async {
      final events = <String>[];
      final catalog = _FileCatalog(
        <LibraryFile?>[_file(sizeBytes: 9)],
        events,
      );
      final artifact = _ArtifactPort(<Object>[], events);
      final reader = _SourceReader(null, events);

      final failure = await _captureFailure(
        _service(
          catalog: catalog,
          artifact: artifact,
          reader: reader,
          maxBytes: 8,
        ).inspect('file-1'),
      );

      expect(
        failure.failure,
        SupplementalSourceInspectionFailure.resourceLimitExceeded,
      );
      expect(events, <String>['file']);
      expect(reader.readCalls, 0);
      expect(artifact.currentReads, 0);
    });

    test('rejects artifact identity or revision drift after reading', () async {
      final failure = await _inspectFailure(
        catalogFiles: <LibraryFile?>[_file(), _file()],
        readResult: _validRead(),
        snapshots: <Object>[
          _snapshot(artifactId: 'artifact-1', revision: 3),
          _snapshot(artifactId: 'artifact-1', revision: 4),
        ],
      );

      expect(
          failure.failure, SupplementalSourceInspectionFailure.artifactChanged);
    });

    test('rejects LibraryFile metadata drift after reading', () async {
      final failure = await _inspectFailure(
        catalogFiles: <LibraryFile?>[
          _file(),
          _file(displayName: 'renamed.pdf'),
        ],
        readResult: _validRead(),
      );

      expect(
        failure.failure,
        SupplementalSourceInspectionFailure.sourceIntegrityMismatch,
      );
    });

    test('maps missing files and artifact failures to typed safe failures',
        () async {
      final missingFile = await _inspectFailure(
        catalogFiles: <LibraryFile?>[null],
        readResult: null,
      );
      expect(
        missingFile.failure,
        SupplementalSourceInspectionFailure.fileUnavailable,
      );
      expect(missingFile.toString(), isNot(contains(_storageKey)));
      expect(missingFile.toString(), isNot(contains('C:\\private')));
      expect(missingFile.toString(), isNot(contains('private source bytes')));

      final artifactFailure = await _inspectFailure(
        catalogFiles: <LibraryFile?>[_file()],
        readResult: _validRead(),
        snapshots: <Object>[StateError('private source bytes at C:\\private')],
      );
      expect(
        artifactFailure.failure,
        SupplementalSourceInspectionFailure.artifactUnavailable,
      );
      expect(
          artifactFailure.toString(), isNot(contains('private source bytes')));
      expect(artifactFailure.toString(), isNot(contains('C:\\private')));
    });
  });
}

SupplementalSourceInspectionService _service({
  required _FileCatalog catalog,
  required _ArtifactPort artifact,
  required _SourceReader reader,
  required int maxBytes,
}) {
  return SupplementalSourceInspectionService(
    fileCatalog: catalog,
    artifactPort: artifact,
    sourceReader: reader,
    maxBytes: maxBytes,
  );
}

Future<SupplementalSourceInspectionException> _inspectFailure({
  required List<LibraryFile?> catalogFiles,
  required SupplementalSourceReadResult? readResult,
  List<Object>? snapshots,
}) {
  final events = <String>[];
  return _captureFailure(
    _service(
      catalog: _FileCatalog(catalogFiles, events),
      artifact: _ArtifactPort(
        snapshots ??
            <Object>[
              _snapshot(artifactId: 'artifact-1', revision: 3),
              _snapshot(artifactId: 'artifact-1', revision: 3),
            ],
        events,
      ),
      reader: _SourceReader(readResult, events),
      maxBytes: 8,
    ).inspect('file-1'),
  );
}

Future<SupplementalSourceInspectionException> _captureFailure(
  Future<SupplementalSourceInspection> result,
) async {
  try {
    await result;
  } on SupplementalSourceInspectionException catch (failure) {
    return failure;
  }
  fail('Expected a typed source-inspection failure.');
}

LibraryFile _file({
  int sizeBytes = 3,
  String sha256 = _abcSha256,
  String displayName = 'source.pdf',
}) {
  return LibraryFile(
    fileId: 'file-1',
    displayName: displayName,
    mimeType: 'application/pdf',
    sizeBytes: sizeBytes,
    sha256: sha256,
    storageKey: _storageKey,
    createdAt: DateTime.utc(2026, 1, 1),
  );
}

SupplementalSourceReadResult _validRead() => SupplementalSourceReadResult(
      bytes: <int>[97, 98, 99],
      actualSizeBytes: 3,
      actualSha256: _abcSha256,
    );

ParsedArtifactSnapshot _snapshot({
  required String artifactId,
  required int revision,
}) {
  return ParsedArtifactSnapshot(
    artifact: ParsedArtifact(
      fileId: 'file-1',
      artifactId: artifactId,
      revision: revision,
      payloadSchemaVersion: 1,
    ),
    sourceDocument: SourceDocument(sourceId: artifactId),
  );
}

final class _FileCatalog extends Fake implements LibraryFileRepositoryPort {
  _FileCatalog(this.responses, this.events);

  final List<LibraryFile?> responses;
  final List<String> events;
  int findCalls = 0;
  int writeCalls = 0;

  @override
  Future<LibraryFile?> findById(String fileId) async {
    events.add('file');
    final index = findCalls++;
    return index < responses.length ? responses[index] : null;
  }

  @override
  Future<void> save(LibraryFile file) async {
    writeCalls++;
    throw StateError('Unexpected metadata write.');
  }

  @override
  Future<List<LibraryFile>> findAll() async {
    writeCalls++;
    throw StateError('Unexpected metadata list call.');
  }
}

final class _ArtifactPort extends Fake implements ParsedArtifactLifecyclePort {
  _ArtifactPort(this.responses, this.events);

  final List<Object> responses;
  final List<String> events;
  int currentReads = 0;
  int mutationCalls = 0;

  @override
  Future<ParsedArtifactSnapshot> getCurrentArtifact(String fileId) async {
    events.add('artifact');
    final response = responses[currentReads++];
    if (response is Exception) throw response;
    if (response is Error) throw response;
    return response as ParsedArtifactSnapshot;
  }

  @override
  Future<ParsedArtifactEnsureResult> ensureParsedArtifact({
    required String fileId,
    required ParsedArtifactParseOptions options,
  }) async {
    mutationCalls++;
    throw StateError('Unexpected artifact ensure.');
  }

  @override
  Future<ParsedArtifactEnsureResult> reparseArtifact({
    required String fileId,
    required ParsedArtifactParseOptions options,
    required int expectedRevision,
  }) async {
    mutationCalls++;
    throw StateError('Unexpected artifact reparse.');
  }

  @override
  Future<void> removeCurrentArtifact({
    required String fileId,
    required int expectedRevision,
  }) async {
    mutationCalls++;
    throw StateError('Unexpected artifact removal.');
  }
}

final class _SourceReader extends Fake implements SupplementalSourceReaderPort {
  _SourceReader(this.result, this.events);

  final SupplementalSourceReadResult? result;
  final List<String> events;
  int readCalls = 0;
  int? lastMaxBytes;

  @override
  Future<SupplementalSourceReadResult> readOriginalBytes({
    required LibraryFile file,
    required int maxBytes,
  }) async {
    events.add('reader');
    readCalls++;
    lastMaxBytes = maxBytes;
    return result!;
  }
}
