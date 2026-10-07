import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

bool get themeEvidenceEnabled =>
    Platform.environment['UI_THEME_VISUAL_EVIDENCE'] == '1';

Future<void> loadThemeEvidenceFonts() async {
  if (!themeEvidenceEnabled) return;
  final textFont = Platform.environment['UI_THEME_TEXT_FONT'];
  final iconFont = Platform.environment['UI_THEME_ICON_FONT'];
  if (textFont != null) {
    await (FontLoader('Roboto')
          ..addFont(Future.value(
              ByteData.sublistView(await File(textFont).readAsBytes()))))
        .load();
  }
  if (iconFont != null) {
    await (FontLoader('MaterialIcons')
          ..addFont(Future.value(
              ByteData.sublistView(await File(iconFont).readAsBytes()))))
        .load();
  }
}

/// Captures synthetic Flutter test rendering, not device/runtime acceptance.
Future<void> captureThemeEvidence(
    WidgetTester tester, GlobalKey key, String name) async {
  if (!themeEvidenceEnabled) return;
  final shadows = debugDisableShadows;
  debugDisableShadows = false;
  try {
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      try {
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        final phase = Platform.environment['UI_POLISH_2_PHASE'];
        final assistantPhase =
            Platform.environment['ASSISTANT_COLOR_EVIDENCE_PHASE'];
        final output = assistantPhase == 'before' || assistantPhase == 'after'
            ? '.dart_tool/assistant-colors-$assistantPhase'
            : phase == 'before' || phase == 'after'
                ? '.dart_tool/ui-polish-2-$phase'
                : '.dart_tool/theme-visual-evidence';
        final directory = await Directory(output).create(recursive: true);
        await File('${directory.path}/$name.png')
            .writeAsBytes(bytes.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  } finally {
    debugDisableShadows = shadows;
  }
}
