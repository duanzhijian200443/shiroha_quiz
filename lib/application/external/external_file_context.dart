part of 'external_read_context.dart';

/// Application-owned safe output. No internal identity is serializable.
final class ExternalFilePage {
  ExternalFilePage(Iterable<Map<String, Object?>> items,
      {this.nextCursor,
      this.hasMore = false,
      this.unsupportedExcluded = false,
      this.startsAtDocumentBeginning = false,
      this.executionEvidence})
      : items = List.unmodifiable(items.map(Map<String, Object?>.unmodifiable));
  final List<Map<String, Object?>> items;
  final String? nextCursor;
  final RetrievalExecutionEvidence? executionEvidence;
  final bool hasMore, unsupportedExcluded, startsAtDocumentBeginning;
  Map<String, Object?> toJson() => {
        'items': items,
        'nextCursor': nextCursor,
        'hasMore': hasMore,
        'unsupportedExcluded': unsupportedExcluded,
        'startsAtDocumentBeginning': startsAtDocumentBeginning
      };
}

extension ExternalFileContextOperations on ExternalReadContextService {
  ExternalFileReader get _fileReader =>
      _files ?? (externalReadFail(ExternalReadFailure.unavailable));

  /// App builds choices exclusively from current exact File scopes. External
  /// callers can select only minted references, never a file/path/Artifact id.
  Future<ExternalFilePage> listFileSelections(
          {required ExternalSession session,
          required String context,
          ExternalCallControl? control}) =>
      _run(session, control, (runtime, check, allocations) async {
        final parent = _lookup(context, _HandleKind.context, runtime);
        final access = ExternalQuestionReadAccess._(this, runtime, parent);
        final choices =
            await _fileReader.authorization.query(access, null, check);
        if (choices.length > 64) {
          externalReadFail(ExternalReadFailure.resourceLimit);
        }
        // Metadata choices bind a generation but do not load document bodies.
        await _fileReader.authorize(access, choices, check);
        final now = admission.trust.clock.now();
        final result = ExternalFilePage([
          for (var i = 0; i < choices.length; i++)
            {
              'fileRef': _mint(
                  _Handle(_HandleKind.fileSelection, runtime, parent.snapshot,
                      now, parent.expiresAt,
                      target: parent.target,
                      parentContext: parent,
                      file: choices[i]),
                  allocations),
              'selectionOrdinal': i
            }
        ]);
        _fileSize(result);
        check();
        access.validate();
        return result;
      });

  /// Creates a separate Context, never upgrades existing empty Contexts. The
  /// new Context expires at the original parent deadline, without renewal.
  Future<String> createFileContext(
          {required ExternalSession session,
          required String context,
          required List<String> fileRefs,
          ExternalCallControl? control}) =>
      _run(session, control, (runtime, check, allocations) async {
        final parent = _lookup(context, _HandleKind.context, runtime);
        if (fileRefs.isEmpty ||
            fileRefs.length > 64 ||
            fileRefs.toSet().length != fileRefs.length) {
          externalReadFail(ExternalReadFailure.invalidRequest);
        }
        final selected = <RetrievalArtifactSnapshot>[];
        for (final ref in fileRefs) {
          final choice = _lookup(ref, _HandleKind.fileSelection, runtime);
          if (!identical(choice.parentContext, parent)) {
            externalReadFail(ExternalReadFailure.denied);
          }
          selected.add(choice.file!);
        }
        final access = ExternalQuestionReadAccess._(this, runtime, parent);
        await _fileReader.release(access, selected, check);
        check();
        access.validate();
        if (maxResponseBytes < 43) {
          externalReadFail(ExternalReadFailure.resourceLimit);
        }
        return _mint(
            _Handle(_HandleKind.context, runtime, parent.snapshot,
                admission.trust.clock.now(), parent.expiresAt,
                target: parent.target,
                parentContext: parent,
                files: List.unmodifiable(selected)),
            allocations);
      });

  Future<T> _fileRun<T>(
      ExternalSession session,
      ExternalCallControl? control,
      RetrievalExecutionEvidence evidence,
      Future<T> Function(ExternalRuntimeAccess, void Function(), List<String>)
          op) async {
    try {
      return await _run(session, control, op);
    } on ExternalReadException catch (error) {
      throw ExternalFileReadException(error.failure, evidence);
    }
  }

  void _fileSize(ExternalFilePage page) {
    if (externalFileEncodedBytes(page.toJson()) >
        min(maxResponseBytes, 24000)) {
      externalReadFail(ExternalReadFailure.resourceLimit);
    }
  }

  Future<ExternalFilePage> retrieveFileContent(
      {required ExternalSession session,
      required String context,
      required String query,
      int limit = 8,
      ExternalCallControl? control,
      void Function()? onDerivedCacheCommitted}) {
    final evidence = RetrievalExecutionEvidence(
        onDerivedCacheCommitted: onDerivedCacheCommitted);
    return _fileRun(session, control, evidence,
        (runtime, check, allocations) async {
      final parent = _lookup(context, _HandleKind.context, runtime);
      final access = ExternalQuestionReadAccess._(this, runtime, parent);
      final result = await _fileReader.retrieve(
          access, parent.files, query, limit, evidence, check);
      final projections = <String, RetrievalChunkProjection>{};
      for (final file in parent.files) {
        projections[file.fileId] =
            await _fileReader.project(access, parent.files, file, check);
      }
      final items = <Map<String, Object?>>[];
      final now = admission.trust.clock.now();
      for (final hit in result.rankedHits) {
        final file =
            parent.files.where((f) => f.fileId == hit.fileId).firstOrNull;
        final chunk = projections[hit.fileId]
            ?.chunks
            .where((c) => c.chunkId == hit.chunkId)
            .firstOrNull;
        if (file == null ||
            chunk == null ||
            hit.artifactId != file.artifactId ||
            hit.revision != file.revision ||
            hit.content != chunk.content ||
            hit.contentKind != chunk.kind) {
          externalReadFail(ExternalReadFailure.stale);
        }
        final ref = _mint(
            _Handle(_HandleKind.passage, runtime, parent.snapshot, now,
                parent.expiresAt,
                target: parent.target,
                parentContext: parent,
                file: file,
                chunkId: chunk.chunkId),
            allocations);
        items.add({'passageRef': ref, ...externalSafeChunk(chunk)});
      }
      final page = ExternalFilePage(items,
          executionEvidence: evidence,
          unsupportedExcluded:
              projections.values.any((p) => p.unsupportedExcluded));
      _fileSize(page);
      await _fileReader.release(access, parent.files, check);
      check();
      access.validate();
      return page;
    });
  }

  Future<ExternalFilePage> getFilePassage(
          {required ExternalSession session,
          required String context,
          required String passageRef,
          String? cursor,
          ExternalCallControl? control}) =>
      _fileRun(session, control, RetrievalExecutionEvidence(),
          (runtime, check, allocations) async {
        final parent = _lookup(context, _HandleKind.context, runtime);
        final anchor = _lookup(passageRef, _HandleKind.passage, runtime);
        if (!identical(anchor.parentContext, parent)) {
          externalReadFail(ExternalReadFailure.denied);
        }
        final continuation = cursor == null
            ? null
            : _lookup(cursor, _HandleKind.passageCursor, runtime);
        if (continuation != null &&
            (!identical(continuation.parentContext, parent) ||
                !identical(continuation.anchor, anchor))) {
          externalReadFail(ExternalReadFailure.denied);
        }
        final access = ExternalQuestionReadAccess._(this, runtime, parent);
        final projection = await _fileReader.project(
            access, parent.files, anchor.file!, check);
        final start = continuation?.offset ??
            projection.chunks.indexWhere((c) => c.chunkId == anchor.chunkId);
        if (start < 0 || start >= projection.chunks.length) {
          externalReadFail(ExternalReadFailure.stale);
        }
        final items = <Map<String, Object?>>[];
        var end = start;
        // Reserve the complete cursor/envelope size before any allocation.
        while (end < projection.chunks.length && items.length < 8) {
          final candidate = [
            ...items,
            externalSafeChunk(projection.chunks[end])
          ];
          final trial = ExternalFilePage(candidate,
              nextCursor: 'x' * 43,
              hasMore: true,
              unsupportedExcluded: projection.unsupportedExcluded,
              startsAtDocumentBeginning: start == 0);
          if (externalFileEncodedBytes(trial.toJson()) >
              min(maxResponseBytes, 24000)) {
            break;
          }
          items.add(candidate.last);
          end++;
        }
        if (items.isEmpty) externalReadFail(ExternalReadFailure.resourceLimit);
        final more = end < projection.chunks.length;
        final next = !more
            ? null
            : _mint(
                _Handle(_HandleKind.passageCursor, runtime, parent.snapshot,
                    admission.trust.clock.now(), parent.expiresAt,
                    target: parent.target,
                    parentContext: parent,
                    file: anchor.file,
                    anchor: anchor,
                    offset: end),
                allocations);
        final page = ExternalFilePage(items,
            nextCursor: next,
            hasMore: more,
            unsupportedExcluded: projection.unsupportedExcluded,
            startsAtDocumentBeginning: start == 0);
        _fileSize(page);
        await _fileReader.release(access, parent.files, check);
        check();
        access.validate();
        return page;
      });
}
