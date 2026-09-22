import 'package:flutter/material.dart';
import 'structured_content_renderer.dart';

/// Uses the existing math renderer without allowing provider text to load
/// remote images or treat markdown paths as student evidence.
class PhotoAnswerTranscription extends StatelessWidget {
  const PhotoAnswerTranscription({super.key, required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    final value = text.trim();
    final bareFormula = value.startsWith(r'\') &&
        !value.startsWith(r'\(') &&
        !value.startsWith(r'\[') &&
        !value.contains(r'$');
    return StructuredContentRenderer(
      text: bareFormula ? r'$$' + value + r'$$' : value,
      imageBuilder: (_, __, ___) => const SizedBox.shrink(),
    );
  }
}
