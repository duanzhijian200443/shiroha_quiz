import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'structured_content_renderer.dart';

class SandboxImageWidget extends StatelessWidget {
  final Uri uri;
  final String? alt;

  const SandboxImageWidget({super.key, required this.uri, this.alt});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Directory>(
      future: getApplicationDocumentsDirectory(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const SizedBox(
            height: 60,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }

        final docDir = snapshot.data!;
        final relativePath = 'media/${uri.host}${uri.path}';
        var file = File('${docDir.path}/$relativePath');

        if (!file.existsSync()) {
          final filename =
              uri.pathSegments.isNotEmpty ? uri.pathSegments.last : '';
          final mediaDir = Directory('${docDir.path}/media/${uri.host}');
          if (filename.isNotEmpty && mediaDir.existsSync()) {
            final found = mediaDir
                .listSync(recursive: true)
                .whereType<File>()
                .where((f) => f.path.replaceAll('\\', '/').endsWith(filename))
                .toList();
            if (found.isNotEmpty) file = found.first;
          }
        }

        if (!file.existsSync()) {
          return Container(
            color: Colors.grey.shade200,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            margin: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.broken_image, color: Colors.grey, size: 20),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    'Image missing: ${alt ?? relativePath}',
                    style: const TextStyle(color: Colors.grey, fontSize: 13),
                  ),
                ),
              ],
            ),
          );
        }

        return Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(
              file,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) =>
                  const Icon(Icons.broken_image, color: Colors.red),
            ),
          ),
        );
      },
    );
  }
}

Widget buildMarkdownImage(Uri uri, String? title, String? alt) {
  if (uri.scheme == 'sandbox') {
    return SandboxImageWidget(uri: uri, alt: alt);
  }
  if (uri.scheme == 'http' || uri.scheme == 'https') {
    return Image.network(
      uri.toString(),
      errorBuilder: (context, error, stackTrace) =>
          const Icon(Icons.broken_image, color: Colors.grey),
    );
  }
  return Text('Unsupported image: ${uri.toString()}');
}

Widget buildLatexWidget(
  BuildContext context,
  String text, {
  Color? textColor,
  double fontSize = 16.0,
  FontWeight fontWeight = FontWeight.normal,
}) {
  return StructuredContentRenderer(
    text: text,
    textColor: textColor,
    fontSize: fontSize,
    fontWeight: fontWeight,
    imageBuilder: (context, uri, alt) => buildMarkdownImage(uri, null, alt),
  );
}
