import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/assets/asset_ref.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/import/import_issue.dart';
import 'package:shiroha_quiz/domain/question/question_region.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';

void main() {
  group('QuestionRegionFragment', () {
    test('keeps each SourcePart subtype as the only content fact', () {
      final sourceRef = _sourceRef('source_a');
      final parts = <SourcePart>[
        _contentPart(sourceRef, 'stem'),
        SourceTablePart(
          sourceRef: sourceRef,
          rows: <List<RichContent>>[
            <RichContent>[_content('cell')],
          ],
        ),
        SourceAssetPart(
          sourceRef: sourceRef,
          asset: AssetRef(assetId: 'asset_a', kind: AssetKind.image),
        ),
        UnsupportedSourcePart(
          sourceRef: sourceRef,
          kindCode: 'future_layout',
          fallbackContent: _content('fallback'),
        ),
      ];

      final fragments = parts
          .map(
            (part) => QuestionRegionFragment(
              field: QuestionRegionField.stem,
              part: part,
            ),
          )
          .toList();

      expect(fragments.map((fragment) => fragment.part), parts);
      for (final fragment in fragments) {
        expect(identical(fragment.sourceRef, fragment.part.sourceRef), isTrue);
        expect(fragment.slice, isNull);
      }
    });

    test('accepts text interiors and whole non-text node boundaries', () {
      final part = SourceContentPart(
        sourceRef: _sourceRef('source_a'),
        content: RichContent(nodes: <ContentNode>[
          const TextNode('alpha'),
          const InlineMathNode(r'x+1'),
          RawFallbackNode(<Object?, Object?>{
            'type': 'future_diagram',
            'payload': <Object?, Object?>{'kind': 'synthetic'},
          }),
          const BlockMathNode(r'\sum x'),
          const TextNode('omega'),
        ]),
      );
      final spanning = SourceSlice(
        startNodeIndex: 0,
        startCodeUnitOffset: 2,
        endNodeIndex: 4,
        endCodeUnitOffset: 3,
      );
      final wholeMath = SourceSlice(
        startNodeIndex: 1,
        startCodeUnitOffset: 0,
        endNodeIndex: 2,
        endCodeUnitOffset: 0,
      );
      final throughEnd = SourceSlice(
        startNodeIndex: 4,
        startCodeUnitOffset: 0,
        endNodeIndex: 5,
        endCodeUnitOffset: 0,
      );

      expect(_fragment(part, slice: spanning).slice, spanning);
      expect(_fragment(part, slice: wholeMath).slice, wholeMath);
      expect(_fragment(part, slice: throughEnd).slice, throughEnd);
    });

    test('uses UTF-16 code-unit offsets for non-BMP text', () {
      final part = SourceContentPart(
        sourceRef: _sourceRef('source_a'),
        content: RichContent(nodes: const <ContentNode>[
          TextNode('A😀B'),
        ]),
      );
      final throughSurrogatePair = SourceSlice(
        startNodeIndex: 0,
        startCodeUnitOffset: 1,
        endNodeIndex: 0,
        endCodeUnitOffset: 3,
      );
      final fromAfterSurrogatePairToNodeEnd = SourceSlice(
        startNodeIndex: 0,
        startCodeUnitOffset: 3,
        endNodeIndex: 1,
        endCodeUnitOffset: 0,
      );

      expect(
        _fragment(part, slice: throughSurrogatePair).slice,
        throughSurrogatePair,
      );
      expect(
        _fragment(part, slice: fromAfterSurrogatePairToNodeEnd).slice,
        fromAfterSurrogatePairToNodeEnd,
      );
      expect(
        () => _fragment(
          part,
          slice: SourceSlice(
            startNodeIndex: 0,
            startCodeUnitOffset: 1,
            endNodeIndex: 0,
            endCodeUnitOffset: 4,
          ),
        ),
        throwsFormatException,
      );
    });

    test('rejects invalid ranges, out-of-bounds positions, and node cuts', () {
      final part = SourceContentPart(
        sourceRef: _sourceRef('source_a'),
        content: RichContent(nodes: <ContentNode>[
          const TextNode('alpha'),
          const InlineMathNode('x'),
          RawFallbackNode(<Object?, Object?>{
            'type': 'future_diagram',
            'payload': <Object?, Object?>{'kind': 'synthetic'},
          }),
          const BlockMathNode('y'),
        ]),
      );

      expect(
        () => SourceSlice(
          startNodeIndex: 1,
          startCodeUnitOffset: 0,
          endNodeIndex: 1,
          endCodeUnitOffset: 0,
        ),
        throwsFormatException,
      );
      expect(
        () => SourceSlice(
          startNodeIndex: -1,
          startCodeUnitOffset: 0,
          endNodeIndex: 0,
          endCodeUnitOffset: 0,
        ),
        throwsFormatException,
      );

      final invalidSlices = <SourceSlice>[
        SourceSlice(
          startNodeIndex: 0,
          startCodeUnitOffset: 0,
          endNodeIndex: 5,
          endCodeUnitOffset: 0,
        ),
        SourceSlice(
          startNodeIndex: 0,
          startCodeUnitOffset: 5,
          endNodeIndex: 1,
          endCodeUnitOffset: 0,
        ),
        SourceSlice(
          startNodeIndex: 1,
          startCodeUnitOffset: 1,
          endNodeIndex: 2,
          endCodeUnitOffset: 0,
        ),
        SourceSlice(
          startNodeIndex: 2,
          startCodeUnitOffset: 1,
          endNodeIndex: 3,
          endCodeUnitOffset: 0,
        ),
        SourceSlice(
          startNodeIndex: 3,
          startCodeUnitOffset: 1,
          endNodeIndex: 4,
          endCodeUnitOffset: 0,
        ),
        SourceSlice(
          startNodeIndex: 3,
          startCodeUnitOffset: 0,
          endNodeIndex: 4,
          endCodeUnitOffset: 1,
        ),
      ];
      for (final slice in invalidSlices) {
        expect(() => _fragment(part, slice: slice), throwsFormatException);
      }
    });

    test('rejects slices for every non-content SourcePart subtype', () {
      final sourceRef = _sourceRef('source_a');
      final slice = SourceSlice(
        startNodeIndex: 0,
        startCodeUnitOffset: 0,
        endNodeIndex: 1,
        endCodeUnitOffset: 0,
      );
      final parts = <SourcePart>[
        SourceTablePart(
          sourceRef: sourceRef,
          rows: <List<RichContent>>[
            <RichContent>[_content('cell')],
          ],
        ),
        SourceAssetPart(
          sourceRef: sourceRef,
          asset: AssetRef(assetId: 'asset_a', kind: AssetKind.image),
        ),
        UnsupportedSourcePart(
          sourceRef: sourceRef,
          kindCode: 'future_layout',
          fallbackContent: _content('fallback'),
        ),
      ];

      for (final part in parts) {
        expect(() => _fragment(part, slice: slice), throwsFormatException);
      }
    });
  });

  group('QuestionRegion derivation', () {
    test('preserves encounter order and returns stable immutable filters', () {
      final inputFragments = <QuestionRegionFragment>[
        _fragment(
          _contentPart(_sourceRef('source_a', pageNumber: 1), 'stem a'),
        ),
        QuestionRegionFragment(
          field: QuestionRegionField.answer,
          part: _contentPart(
            _sourceRef('source_a', pageNumber: 2),
            'answer',
          ),
        ),
        _fragment(
          _contentPart(_sourceRef('source_b', pageNumber: 1), 'stem b'),
        ),
      ];
      final inputIssues = <ImportIssue>[
        ImportIssue(code: 'synthetic_info', severity: ImportIssueSeverity.info),
      ];
      final region = QuestionRegion(
        questionNumber: 7,
        fragments: inputFragments,
        issues: inputIssues,
      );

      inputFragments.clear();
      inputIssues.clear();

      expect(region.fragments.map((fragment) => fragment.field), <Object?>[
        QuestionRegionField.stem,
        QuestionRegionField.answer,
        QuestionRegionField.stem,
      ]);
      expect(region.fragmentsFor(QuestionRegionField.stem), <Object?>[
        region.fragments[0],
        region.fragments[2],
      ]);
      expect(region.fragmentsFor(QuestionRegionField.answer), <Object?>[
        region.fragments[1],
      ]);
      expect(() => region.fragments.clear(), throwsUnsupportedError);
      expect(() => region.issues.clear(), throwsUnsupportedError);
      expect(
        () => region.fragmentsFor(QuestionRegionField.stem).clear(),
        throwsUnsupportedError,
      );
    });

    test('derives source refs in first-encounter value order', () {
      final first = _sourceRef('source_a', pageNumber: 1);
      final equalFirst = _sourceRef('source_a', pageNumber: 1);
      final second = _sourceRef('source_a', pageNumber: 2);
      final third = _sourceRef('source_b', pageNumber: 1);
      final region = QuestionRegion(
        questionNumber: 1,
        fragments: <QuestionRegionFragment>[
          _fragment(_contentPart(first, 'stem')),
          _fragment(_contentPart(equalFirst, 'duplicate')),
          _fragment(_contentPart(second, 'next')),
          _fragment(_contentPart(third, 'other source')),
        ],
      );

      expect(region.sourceRefs, <SourceRef>[first, second, third]);
      expect(() => region.sourceRefs.clear(), throwsUnsupportedError);
    });

    test('derives source-qualified assets and rejects metadata conflicts', () {
      AssetRef asset({required int width}) => AssetRef(
            assetId: 'asset_shared',
            kind: AssetKind.image,
            mimeType: 'image/png',
            pixelWidth: width,
            pixelHeight: width,
          );

      final firstAsset = asset(width: 10);
      final region = QuestionRegion(
        questionNumber: 1,
        fragments: <QuestionRegionFragment>[
          _fragment(_contentPart(_sourceRef('source_a'), 'stem')),
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: SourceAssetPart(
              sourceRef: _sourceRef('source_a'),
              asset: firstAsset,
            ),
          ),
          QuestionRegionFragment(
            field: QuestionRegionField.answer,
            part: SourceAssetPart(
              sourceRef: _sourceRef('source_a', pageNumber: 2),
              asset: asset(width: 10),
            ),
          ),
          QuestionRegionFragment(
            field: QuestionRegionField.explanation,
            part: SourceAssetPart(
              sourceRef: _sourceRef('source_b'),
              asset: asset(width: 20),
            ),
          ),
        ],
      );

      expect(region.assetRefs, hasLength(2));
      expect(region.assetRefs[0].sourceId, 'source_a');
      expect(region.assetRefs[0].asset, firstAsset);
      expect(region.assetRefs[1].sourceId, 'source_b');
      expect(region.assetRefs[1].localAssetId, 'asset_shared');
      expect(() => region.assetRefs.clear(), throwsUnsupportedError);

      expect(
        () => QuestionRegion(
          questionNumber: 1,
          fragments: <QuestionRegionFragment>[
            _fragment(_contentPart(_sourceRef('source_a'), 'stem')),
            QuestionRegionFragment(
              field: QuestionRegionField.stem,
              part: SourceAssetPart(
                sourceRef: _sourceRef('source_a'),
                asset: asset(width: 10),
              ),
            ),
            QuestionRegionFragment(
              field: QuestionRegionField.answer,
              part: SourceAssetPart(
                sourceRef: _sourceRef('source_a', pageNumber: 2),
                asset: asset(width: 11),
              ),
            ),
          ],
        ),
        throwsFormatException,
      );
    });

    test('deduplicates repeated placements while retaining first asset order',
        () {
      final first = SourceAssetPart(
        sourceRef: _sourceRef('source_a', pageNumber: 1),
        asset: AssetRef(assetId: 'asset_a', kind: AssetKind.image),
      );
      final second = SourceAssetPart(
        sourceRef: _sourceRef('source_a', pageNumber: 2),
        asset: AssetRef(assetId: 'asset_b', kind: AssetKind.image),
      );
      final region = QuestionRegion(
        questionNumber: 1,
        fragments: <QuestionRegionFragment>[
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: first,
          ),
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: first,
          ),
          QuestionRegionFragment(
            field: QuestionRegionField.stem,
            part: second,
          ),
        ],
      );

      expect(
        region.assetRefs.map((asset) => asset.localAssetId),
        <String>['asset_a', 'asset_b'],
      );
    });

    test('shares slice materialization semantics with the public helper', () {
      final content = RichContent(nodes: <ContentNode>[
        const TextNode('前段'),
        const InlineMathNode('x'),
        const TextNode('后段'),
      ]);
      final slice = SourceSlice(
        startNodeIndex: 0,
        startCodeUnitOffset: 1,
        endNodeIndex: 2,
        endCodeUnitOffset: 1,
      );

      expect(
        materializeQuestionRegionContent(content, slice),
        <ContentNode>[
          const TextNode('段'),
          const InlineMathNode('x'),
          const TextNode('后'),
        ],
      );
    });

    test('requires issue source IDs to belong to a fragment source', () {
      final fragments = <QuestionRegionFragment>[
        _fragment(_contentPart(_sourceRef('source_a'), 'stem')),
      ];

      expect(
        QuestionRegion(
          questionNumber: 1,
          fragments: fragments,
          issues: <ImportIssue>[
            ImportIssue(
              code: 'same_source',
              severity: ImportIssueSeverity.info,
              sourceRef: _sourceRef('source_a', pageNumber: 3),
            ),
          ],
        ).issues,
        hasLength(1),
      );
      expect(
        () => QuestionRegion(
          questionNumber: 1,
          fragments: fragments,
          issues: <ImportIssue>[
            ImportIssue(
              code: 'foreign_source',
              severity: ImportIssueSeverity.warning,
              sourceRef: _sourceRef('source_b'),
            ),
          ],
        ),
        throwsFormatException,
      );
    });
  });

  group('QuestionRegion validity and readiness', () {
    test('rejects the three unsupported no-stem issue cases', () {
      final answerOnly = <QuestionRegionFragment>[
        QuestionRegionFragment(
          field: QuestionRegionField.answer,
          part: _contentPart(_sourceRef('source_a'), 'answer'),
        ),
      ];
      final invalidIssues = <List<ImportIssue>>[
        const <ImportIssue>[],
        <ImportIssue>[
          ImportIssue(
            code: 'stem_info',
            severity: ImportIssueSeverity.info,
            field: ImportIssueField.stem,
          ),
        ],
        <ImportIssue>[
          ImportIssue(
            code: 'answer_warning',
            severity: ImportIssueSeverity.warning,
            field: ImportIssueField.answer,
          ),
        ],
      ];

      for (final issues in invalidIssues) {
        expect(
          () => QuestionRegion(
            questionNumber: 1,
            fragments: answerOnly,
            issues: issues,
          ),
          throwsFormatException,
        );
      }
    });

    test('maps warnings and errors to readiness, including no-stem review', () {
      final stem = <QuestionRegionFragment>[
        _fragment(_contentPart(_sourceRef('source_a'), 'stem')),
      ];
      final answerOnly = <QuestionRegionFragment>[
        QuestionRegionFragment(
          field: QuestionRegionField.answer,
          part: _contentPart(_sourceRef('source_a'), 'answer'),
        ),
      ];

      expect(
        QuestionRegion(questionNumber: 1, fragments: stem).readiness,
        QuestionRegionReadiness.ready,
      );
      expect(
        QuestionRegion(
          questionNumber: 1,
          fragments: stem,
          issues: <ImportIssue>[
            ImportIssue(
              code: 'review_warning',
              severity: ImportIssueSeverity.warning,
            ),
          ],
        ).readiness,
        QuestionRegionReadiness.needsReview,
      );
      expect(
        QuestionRegion(
          questionNumber: 1,
          fragments: answerOnly,
          issues: <ImportIssue>[
            ImportIssue(
              code: 'missing_stem',
              severity: ImportIssueSeverity.warning,
              field: ImportIssueField.stem,
            ),
          ],
        ).readiness,
        QuestionRegionReadiness.needsReview,
      );
      expect(
        QuestionRegion(
          questionNumber: 1,
          fragments: answerOnly,
          issues: <ImportIssue>[
            ImportIssue(
              code: 'question_rejected',
              severity: ImportIssueSeverity.error,
              field: ImportIssueField.question,
            ),
          ],
        ).readiness,
        QuestionRegionReadiness.rejected,
      );
    });

    test('requires a positive number and at least one fragment', () {
      final stem = <QuestionRegionFragment>[
        _fragment(_contentPart(_sourceRef('source_a'), 'stem')),
      ];

      for (final number in <int>[0, -1]) {
        expect(
          () => QuestionRegion(questionNumber: number, fragments: stem),
          throwsFormatException,
        );
      }
      expect(
        () => QuestionRegion(
          questionNumber: 1,
          fragments: const <QuestionRegionFragment>[],
        ),
        throwsFormatException,
      );
    });

    test('uses structural equality and hashes for every contract class', () {
      SourceSlice slice() => SourceSlice(
            startNodeIndex: 0,
            startCodeUnitOffset: 1,
            endNodeIndex: 0,
            endCodeUnitOffset: 3,
          );
      QuestionRegion build() => QuestionRegion(
            questionNumber: 4,
            kindHint: QuestionRegionKindHint.shortAnswer,
            fragments: <QuestionRegionFragment>[
              QuestionRegionFragment(
                field: QuestionRegionField.stem,
                part: _contentPart(_sourceRef('source_a'), 'alpha'),
                slice: slice(),
              ),
            ],
            issues: <ImportIssue>[
              ImportIssue(
                code: 'synthetic_info',
                severity: ImportIssueSeverity.info,
              ),
            ],
          );

      final firstSlice = slice();
      final equalSlice = slice();
      expect(equalSlice, firstSlice);
      expect(equalSlice.hashCode, firstSlice.hashCode);

      final first = build();
      final equal = build();
      expect(equal.fragments.single, first.fragments.single);
      expect(equal.fragments.single.hashCode, first.fragments.single.hashCode);
      expect(equal, first);
      expect(equal.hashCode, first.hashCode);
      expect(<QuestionRegion>{first}, contains(equal));
      expect(first.kindHint, QuestionRegionKindHint.shortAnswer);
      expect(
        QuestionRegion(
          questionNumber: 4,
          fragments: first.fragments,
        ),
        isNot(first),
      );
    });
  });
}

QuestionRegionFragment _fragment(
  SourcePart part, {
  SourceSlice? slice,
}) {
  return QuestionRegionFragment(
    field: QuestionRegionField.stem,
    part: part,
    slice: slice,
  );
}

SourceContentPart _contentPart(SourceRef sourceRef, String text) {
  return SourceContentPart(sourceRef: sourceRef, content: _content(text));
}

RichContent _content(String text) {
  return RichContent(nodes: <ContentNode>[TextNode(text)]);
}

SourceRef _sourceRef(String sourceId, {int pageNumber = 1}) {
  return SourceRef.at(
    sourceId: sourceId,
    point: SourcePoint.page(pageNumber: pageNumber),
  );
}
