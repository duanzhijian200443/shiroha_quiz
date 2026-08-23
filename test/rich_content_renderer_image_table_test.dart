import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/content/content_asset_authority.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart'
    as domain_content;
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/services/file_library/managed_content_asset_store.dart';
import 'package:shiroha_quiz/ui/widgets/structured_content_renderer.dart';

void main() {
  testWidgets('shared renderer resolves ImageNode and renders TableNode',
      (tester) async {
    final temp = Directory.systemTemp.createTempSync('rich_renderer_');
    try {
      final store = ManagedContentAssetStore(managedRoot: temp);
      store.storeBytesSync(
        sourceId: 'source_001',
        localAssetId: 'asset_000001',
        bytes: base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
          '+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
        mimeType: 'image/png',
      );
      final content = RichContent(
        nodes: <domain_content.ContentNode>[
          domain_content.ImageNode(
            sourceId: 'source_001',
            localAssetId: 'asset_000001',
          ),
          domain_content.TableNode(
            structure:
                domain_content.TableStructure(rows: <domain_content.TableRow>[
              domain_content.TableRow(cells: <domain_content.TableCell>[
                domain_content.TableCell(
                  content: RichContent(
                    nodes: const <domain_content.ContentNode>[
                      domain_content.TextNode('table cell'),
                    ],
                  ),
                ),
              ]),
            ]),
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RichContentRenderer(
              content: content,
              assetResolver: _PreResolvedResolver(
                store.readAssetBytes(
                  sourceId: 'source_001',
                  localAssetId: 'asset_000001',
                )!,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      expect(
        find.textContaining('table cell', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('[图片]'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    }
  });

  testWidgets('typed TextNode is rendered as literal text', (tester) async {
    final content = RichContent(
      nodes: <domain_content.ContentNode>[
        domain_content.TextNode('Fill ___ and **literal** text'),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RichContentRenderer(content: content),
        ),
      ),
    );

    expect(
      find.text('Fill ___ and **literal** text', findRichText: true),
      findsOneWidget,
    );
    expect(find.byType(BlankTokenWidget), findsNothing);
  });

  testWidgets('TableNode renderer preserves row and column spans',
      (tester) async {
    final content = RichContent(
      nodes: <domain_content.ContentNode>[
        domain_content.TableNode(
          structure: domain_content.TableStructure(
            rows: <domain_content.TableRow>[
              domain_content.TableRow(
                cells: <domain_content.TableCell>[
                  domain_content.TableCell(
                    rowSpan: 2,
                    columnSpan: 2,
                    content: RichContent(
                      nodes: const <domain_content.ContentNode>[
                        domain_content.TextNode('spanned'),
                      ],
                    ),
                  ),
                  domain_content.TableCell(
                    content: RichContent(
                      nodes: const <domain_content.ContentNode>[
                        domain_content.TextNode('head'),
                      ],
                    ),
                  ),
                ],
              ),
              domain_content.TableRow(
                cells: <domain_content.TableCell>[
                  domain_content.TableCell(
                    content: RichContent(
                      nodes: const <domain_content.ContentNode>[
                        domain_content.TextNode('tail'),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: RichContentRenderer(content: content),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('spanned', findRichText: true), findsOneWidget);
    expect(find.text('tail', findRichText: true), findsOneWidget);
    final spanned = tester.getSize(
      find.byKey(const ValueKey<String>('rich-table-anchor-0-0')),
    );
    final tail = tester.getSize(
      find.byKey(const ValueKey<String>('rich-table-anchor-1-2')),
    );
    expect(spanned.width, greaterThan(tail.width * 1.5));
    expect(spanned.height, greaterThan(tail.height * 1.5));
  });

  testWidgets('missing or corrupt ImageNode bytes use a safe fallback',
      (tester) async {
    final content = RichContent(
      nodes: <domain_content.ContentNode>[
        domain_content.ImageNode(
          sourceId: 'source_001',
          localAssetId: 'asset_000001',
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RichContentRenderer(
            content: content,
            assetResolver: const _CorruptResolver(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('[图片]'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

final class _CorruptResolver implements ContentAssetResolver {
  const _CorruptResolver();

  @override
  List<int>? resolveAssetBytes({
    required String sourceId,
    required String localAssetId,
  }) =>
      const <int>[1, 2, 3];

  @override
  Future<List<int>?> resolveAssetBytesAsync({
    required String sourceId,
    required String localAssetId,
  }) async =>
      const <int>[1, 2, 3];
}

final class _PreResolvedResolver implements ContentAssetResolver {
  const _PreResolvedResolver(this.bytes);

  final List<int> bytes;

  @override
  List<int>? resolveAssetBytes({
    required String sourceId,
    required String localAssetId,
  }) =>
      bytes;

  @override
  Future<List<int>?> resolveAssetBytesAsync({
    required String sourceId,
    required String localAssetId,
  }) async =>
      bytes;
}
