import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/assets/asset_ref.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/source/source_document.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/services/retrieval/deterministic_source_chunker.dart';

void main() {
  const chunker = DeterministicSourceChunker();
  SourceRef ref(String source, int page, String block, int order) =>
      SourceRef.at(
          sourceId: source,
          displayLabel: 'public.pdf',
          point: SourcePoint.block(
              pageNumber: page, blockId: block, readingOrder: order));

  test('stable identity distinguishes duplicates and reparse generation', () {
    SourceDocument document(String source) => SourceDocument(
            sourceId: source,
            displayLabel: 'public.pdf',
            parts: <SourcePart>[
              SourceContentPart(
                  sourceRef: ref(source, 1, 'a', 0),
                  content: RichContent(nodes: const [TextNode('duplicate')]),
                  role: SourceContentRole.paragraph),
              SourceContentPart(
                  sourceRef: ref(source, 1, 'b', 1),
                  content: RichContent(nodes: const [TextNode('duplicate')]),
                  role: SourceContentRole.paragraph),
            ]);
    final first = chunker.project(
        fileId: 'file-1',
        artifactId: 'artifact-1',
        revision: 1,
        document: document('artifact-1'));
    final again = chunker.project(
        fileId: 'file-1',
        artifactId: 'artifact-1',
        revision: 1,
        document: document('artifact-1'));
    final reparsed = chunker.project(
        fileId: 'file-1',
        artifactId: 'artifact-2',
        revision: 2,
        document: document('artifact-2'));
    expect(
        first.chunks.map((c) => c.chunkId), again.chunks.map((c) => c.chunkId));
    expect(first.chunks[0].chunkId, isNot(first.chunks[1].chunkId));
    expect(first.chunks[0].chunkId, isNot(reparsed.chunks[0].chunkId));
  });

  test('projects structure safely and never indexes RawFallback', () {
    const source = 'artifact-1';
    final document = SourceDocument(
        sourceId: source,
        displayLabel: 'public.pdf',
        parts: <SourcePart>[
          SourceContentPart(
              sourceRef: ref(source, 1, 'h', 0),
              content: RichContent(nodes: const [TextNode('二次函数')]),
              role: SourceContentRole.heading),
          SourceContentPart(
              sourceRef: ref(source, 1, 'p', 1),
              content: RichContent(nodes: [
                const TextNode('正文'),
                const InlineMathNode('x^2'),
                RawFallbackNode({
                  'type': 'raw_fallback',
                  'payload': {'opaque': 'never-index'}
                })
              ])),
          SourceTablePart(sourceRef: ref(source, 2, 't', 0), rows: [
            for (var i = 0; i < 13; i++)
              [
                RichContent(nodes: [TextNode('row$i')])
              ]
          ]),
          SourceAssetPart(
              sourceRef: ref(source, 3, 'i', 0),
              asset: AssetRef(
                  assetId: 'asset-1',
                  kind: AssetKind.image,
                  mimeType: 'image/png'),
              alternativeText: RichContent(nodes: const [TextNode('坐标图')])),
          UnsupportedSourcePart(
              sourceRef: ref(source, 4, 'u', 0),
              kindCode: 'raw_payload',
              fallbackContent:
                  RichContent(nodes: const [TextNode('must not index')])),
        ]);
    final result = chunker.project(
        fileId: 'file-1', artifactId: source, revision: 1, document: document);
    expect(result.unsupportedExcluded, isTrue);
    expect(result.chunks.map((c) => c.content).join('\n'),
        isNot(contains('never-index')));
    expect(result.chunks.map((c) => c.content).join('\n'),
        isNot(contains('must not index')));
    expect(result.chunks.where((c) => c.kind.name == 'table'), hasLength(2));
    expect(
        result.chunks
            .where((c) => c.kind.name == 'table')
            .map((c) => c.locator),
        everyElement(contains('/rows:')));
    expect(result.chunks.map((c) => c.content).join('\n'), contains('r1c1:'));
    expect(
        result.chunks.singleWhere((c) => c.content == '坐标图').heading, '二次函数');
    expect(result.chunks.any((c) => c.locator.contains('p3:b')), isTrue);
  });

  test('oversized scalar windows are bounded, overlapping, and deterministic',
      () {
    const source = 'artifact-1';
    final text = List.filled(2500, '数').join();
    final document =
        SourceDocument(sourceId: source, displayLabel: 'public.pdf', parts: [
      SourceContentPart(
          sourceRef: ref(source, 1, 'long', 0),
          content: RichContent(nodes: [TextNode(text)]))
    ]);
    final chunks = chunker
        .project(
            fileId: 'file-1',
            artifactId: source,
            revision: 1,
            document: document)
        .chunks;
    expect(chunks, hasLength(3));
    expect(chunks.every((c) => c.content.runes.length <= 1200), isTrue);
    expect(
        chunks[0].content.runes.take(200), chunks[1].content.runes.take(200));
  });
}
