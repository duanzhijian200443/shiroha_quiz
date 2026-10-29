import 'package:flutter/material.dart';
import '../../application/u1_workspace/u1_workspace_dtos.dart';
import '../../domain/content/content_node.dart';
import '../../domain/content/rich_content.dart';
import '../../domain/source/source_part.dart';
import '../widgets/structured_content_renderer.dart';

/// Local display only; opening rereads the existing verified-current F1 seam.
class LibraryArtifactBodyPage extends StatefulWidget {
  const LibraryArtifactBodyPage({super.key, required this.load});
  final Future<LibraryFileArtifactState> Function() load;
  @override
  State<LibraryArtifactBodyPage> createState() => _BodyState();
}

class _BodyState extends State<LibraryArtifactBodyPage> {
  late Future<LibraryFileArtifactState> _snapshot;
  @override
  void initState() {
    super.initState();
    _snapshot = widget.load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('已解析正文'), actions: [
        IconButton(
            tooltip: '重新读取当前产物',
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() {
                  _snapshot = widget.load();
                }))
      ]),
      body: FutureBuilder<LibraryFileArtifactState>(
          future: _snapshot,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final state = snapshot.data;
            final document = state?.document;
            if (snapshot.hasError ||
                state?.status != LibraryFileArtifactStatus.available ||
                document == null) {
              return Center(child: Text(state?.errorMessage ?? '当前解析正文不可读取'));
            }
            return ListView.builder(
                padding: const EdgeInsets.all(20),
                itemCount: document.parts.length + 1,
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return Padding(
                        padding: const EdgeInsets.only(bottom: 20),
                        child: Text(
                            '本次读取：revision ${state!.revision} · ${document.parts.length} 个结构段。\n'
                            '按当前产物顺序显示，无法展示的结构会标明。此页的显示范围不代表 Codex 已完整读取。'));
                  }
                  final part = document.parts[index - 1];
                  final Widget body = switch (part) {
                    SourceContentPart(:final content) =>
                      RichContentRenderer(content: content),
                    SourceTablePart(:final structure) when structure != null =>
                      RichContentRenderer(
                          content: RichContent(
                              nodes: [TableNode(structure: structure)])),
                    SourceAssetPart(:final alternativeText)
                        when alternativeText != null =>
                      RichContentRenderer(content: alternativeText),
                    SourceAssetPart() => const Text('图片：没有可显示的替代文字'),
                    SourceTablePart() => const Text('此表格结构暂不可显示'),
                    UnsupportedSourcePart() => const Text('此结构暂不可显示'),
                  };
                  return Padding(
                      padding: const EdgeInsets.only(bottom: 24),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('段 $index',
                                style: Theme.of(context).textTheme.labelSmall),
                            body,
                          ]));
                });
          }));
}
