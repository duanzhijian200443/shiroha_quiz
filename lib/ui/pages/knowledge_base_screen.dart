import 'package:flutter/material.dart';

class KnowledgeBaseScreen extends StatelessWidget {
  const KnowledgeBaseScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('RAG 专属知识库')),
      body: const Center(child: Text('知识库正在建设中...')),
    );
  }
}
