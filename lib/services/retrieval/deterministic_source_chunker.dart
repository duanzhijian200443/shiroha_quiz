library;

// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../domain/content/content_node.dart';
import '../../domain/content/rich_content.dart';
import '../../domain/retrieval/retrieval_chunk.dart';
import '../../domain/source/source_document.dart';
import '../../domain/source/source_part.dart';
import '../../domain/source/source_ref.dart';
import '../../application/retrieval/retrieval_ports.dart';

final class DeterministicSourceChunker implements RetrievalChunkerPort {
  const DeterministicSourceChunker();

  static const String chunkerVersion = 'rag1.chunk.v1';
  @override
  String get version => chunkerVersion;
  static const int maxScalars = 1200;
  static const int overlapScalars = 200;
  static const int tableRowsPerGroup = 12;

  @override
  RetrievalChunkProjection project({
    required String fileId,
    required String artifactId,
    required int revision,
    required SourceDocument document,
  }) {
    if (document.documentRef.sourceId != artifactId) {
      throw const FormatException(
          'Retrieval source must bind to the artifact.');
    }
    final chunks = <RetrievalChunk>[];
    var nearestHeading = <String, String?>{};
    String? heading;
    var excluded = false;
    for (var partOrdinal = 0;
        partOrdinal < document.parts.length;
        partOrdinal++) {
      final part = document.parts[partOrdinal];
      final projected = _projectPart(part);
      if (projected.excluded) excluded = true;
      if (projected.texts.isEmpty) continue;
      if (part is SourceContentPart && part.role == SourceContentRole.heading) {
        heading = projected.texts.join('\n').trim();
      }
      nearestHeading['$partOrdinal'] = heading;
      var localWindow = 0;
      for (var textOrdinal = 0;
          textOrdinal < projected.texts.length;
          textOrdinal++) {
        final text = projected.texts[textOrdinal];
        for (final window in _windows(text)) {
          final normalized = _normalize(window);
          if (normalized.isEmpty) continue;
          final locator = _locator(
              part.sourceRef,
              partOrdinal,
              localWindow,
              projected.locatorSuffixes.isEmpty
                  ? ''
                  : projected.locatorSuffixes[textOrdinal]);
          final contentHash = _sha(normalized);
          final chunkId = _sha(<String>[
            chunkerVersion,
            fileId,
            artifactId,
            '$revision',
            document.documentRef.sourceId,
            locator,
            '$partOrdinal',
            '$localWindow',
            contentHash,
          ].join('\n'));
          chunks.add(RetrievalChunk(
            chunkId: chunkId,
            fileId: fileId,
            artifactId: artifactId,
            revision: revision,
            sourceId: document.documentRef.sourceId,
            ordinal: chunks.length,
            kind: projected.kind,
            locator: locator,
            partOrdinal: partOrdinal,
            windowOrdinal: localWindow,
            content: normalized,
            contentHash: contentHash,
            heading: nearestHeading['$partOrdinal'],
            sourceRef: part.sourceRef,
          ));
          localWindow++;
        }
      }
    }
    return RetrievalChunkProjection(
        chunks: chunks, unsupportedExcluded: excluded);
  }

  _PartProjection _projectPart(SourcePart part) {
    return switch (part) {
      SourceContentPart(:final content, :final role) => _PartProjection(
          kind: switch (role) {
            SourceContentRole.heading => RetrievalContentKind.heading,
            SourceContentRole.formula => RetrievalContentKind.formula,
            SourceContentRole.answerLike => RetrievalContentKind.answerLike,
            _ => RetrievalContentKind.paragraph,
          },
          texts: [_safeText(content)],
          excluded: _containsRaw(content),
        ),
      SourceTablePart(:final rows) => _projectTable(rows),
      SourceAssetPart(:final alternativeText) => _PartProjection(
          kind: RetrievalContentKind.imageAlt,
          texts: alternativeText == null
              ? const <String>[]
              : <String>[_safeText(alternativeText)],
          excluded: alternativeText != null && _containsRaw(alternativeText),
        ),
      UnsupportedSourcePart() => const _PartProjection(
          kind: RetrievalContentKind.paragraph,
          texts: <String>[],
          excluded: true,
        ),
    };
  }

  String _safeText(RichContent content) => content.nodes
      .where((node) => node is! RawFallbackNode)
      .map((node) => switch (node) {
            TextNode(:final text) => text,
            InlineMathNode(:final latex) => '\\($latex\\)',
            BlockMathNode(:final latex) => '\\[$latex\\]',
            ImageNode() => '',
            TableNode() => '',
            RawFallbackNode() => '',
          })
      .where((value) => value.isNotEmpty)
      .join('\n');

  bool _containsRaw(RichContent content) =>
      content.nodes.any((node) => node is RawFallbackNode);

  _PartProjection _projectTable(List<List<RichContent>> rows) {
    final texts = <String>[];
    final suffixes = <String>[];
    for (var start = 0; start < rows.length; start += tableRowsPerGroup) {
      final end = (start + tableRowsPerGroup).clamp(0, rows.length);
      texts.add(<String>[
        for (var row = start; row < end; row++)
          <String>[
            for (var cell = 0; cell < rows[row].length; cell++)
              'r${row + 1}c${cell + 1}: ${_safeText(rows[row][cell])}'
          ].join(' | ')
      ].join('\n'));
      suffixes.add('/rows:${start + 1}-$end');
    }
    return _PartProjection(
      kind: RetrievalContentKind.table,
      texts: texts,
      locatorSuffixes: suffixes,
      excluded: rows.expand((row) => row).any(_containsRaw),
    );
  }

  Iterable<String> _windows(String input) sync* {
    final scalars = input.runes.toList(growable: false);
    if (scalars.isEmpty) return;
    var start = 0;
    while (start < scalars.length) {
      var end = (start + maxScalars).clamp(0, scalars.length);
      if (end < scalars.length) {
        final lower = start + overlapScalars;
        var cut = end;
        while (cut > lower && scalars[cut - 1] != 10) {
          cut--;
        }
        if (cut <= lower) {
          cut = end;
          while (cut > lower && !_isWhitespace(scalars[cut - 1])) {
            cut--;
          }
        }
        if (cut > lower) end = cut;
      }
      yield String.fromCharCodes(scalars.sublist(start, end));
      if (end == scalars.length) break;
      start = (end - overlapScalars).clamp(start + 1, end);
    }
  }

  bool _isWhitespace(int scalar) =>
      scalar == 9 || scalar == 10 || scalar == 13 || scalar == 32;
  String _normalize(String value) => value
      .replaceAll(RegExp(r'[\t\r ]+'), ' ')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
  String _sha(String value) => sha256.convert(utf8.encode(value)).toString();
  String _locator(SourceRef ref, int part, int window, String locatorSuffix) {
    final point = ref.start;
    final source = point == null
        ? 'document'
        : 'p${point.pageNumber}${point.blockId == null ? '' : ':b${point.blockId}:r${point.readingOrder}'}';
    return '$source/part:$part$locatorSuffix/window:$window';
  }
}

final class _PartProjection {
  const _PartProjection(
      {required this.kind,
      required this.texts,
      this.locatorSuffixes = const <String>[],
      required this.excluded});
  final RetrievalContentKind kind;
  final List<String> texts;
  final List<String> locatorSuffixes;
  final bool excluded;
}
