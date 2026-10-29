import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/u1_workspace/u1_workspace_dtos.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/source/source_document.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/ui/assistant/library_artifact_body_page.dart';
import 'package:shiroha_quiz/ui/widgets/structured_content_renderer.dart';

void main() {
  testWidgets(
      'local body view preserves structure and refuses stale fallback after refresh',
      (tester) async {
    var calls = 0;
    final document = SourceDocument(sourceId: 'artifact', parts: [
      SourceContentPart(
          sourceRef: SourceRef.document(sourceId: 'artifact'),
          content: RichContent(nodes: const [TextNode('literal **first**')])),
      SourceContentPart(
          sourceRef: SourceRef.document(sourceId: 'artifact'),
          content: RichContent(nodes: const [TextNode('second body')])),
      UnsupportedSourcePart(
          sourceRef: SourceRef.document(sourceId: 'artifact'),
          kindCode: 'opaque',
          fallbackContent:
              RichContent(nodes: const [TextNode('not displayed')])),
    ]);
    await tester
        .pumpWidget(MaterialApp(home: LibraryArtifactBodyPage(load: () async {
      calls++;
      if (calls > 1) {
        return const LibraryFileArtifactState(
            status: LibraryFileArtifactStatus.failed,
            errorMessage: '文件内容解析数据已损坏');
      }
      return LibraryFileArtifactState(
          status: LibraryFileArtifactStatus.available,
          revision: 2,
          document: document);
    })));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.textContaining('不代表 Codex 已完整读取'), findsOneWidget);
    final content = tester
        .widgetList<RichContentRenderer>(find.byType(RichContentRenderer))
        .toList();
    expect(content.map((w) => (w.content.nodes.single as TextNode).text),
        ['literal **first**', 'second body']);
    expect(find.text('此结构暂不可显示'), findsOneWidget);
    await tester.tap(find.byTooltip('重新读取当前产物'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('文件内容解析数据已损坏'), findsOneWidget);
    expect(find.byType(RichContentRenderer), findsNothing);
  });
}
