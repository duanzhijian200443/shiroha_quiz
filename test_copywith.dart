import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter/material.dart';

void main() {
  var sheet = MarkdownStyleSheet(
    code: const TextStyle(color: Colors.red, backgroundColor: Colors.white),
  );
  var newSheet = sheet.copyWith(
    code: const TextStyle(color: Colors.blue, backgroundColor: Colors.transparent),
  );
  print('Color: ${newSheet.code?.color}');
  print('BgColor: ${newSheet.code?.backgroundColor}');
}
