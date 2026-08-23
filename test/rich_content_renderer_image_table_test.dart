import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
              assetResolver: store,
            ),
          ),
        ),
      );
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
}
