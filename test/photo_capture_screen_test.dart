import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_parse_request.dart';
import 'package:shiroha_quiz/ui/pages/photo_capture_screen.dart';
import 'package:shiroha_quiz/ui/theme/app_theme.dart';

void main() {
  final syntheticPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  );

  Future<void> pumpLauncher(
    WidgetTester tester, {
    required PhotoPicker pickPhoto,
    required PhotoRecognitionDispatcher dispatch,
    ThemeData? theme,
  }) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: theme ?? AppTheme.lightTheme,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                key: const ValueKey<String>('open-photo-capture'),
                onPressed: () => Navigator.of(context).push<bool>(
                  MaterialPageRoute<bool>(
                    builder: (_) => PhotoCaptureScreen(
                      pickPhoto: pickPhoto,
                      onRecognitionRequested: dispatch,
                    ),
                  ),
                ),
                child: const Text('打开拍照识题'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey<String>('open-photo-capture')));
    await tester.pumpAndSettle();
  }

  XFile syntheticPhoto(Uint8List bytes) => XFile.fromData(
        bytes,
        name: 'synthetic.png',
        mimeType: 'image/png',
      );

  testWidgets('capture shell is presentation-only before a photo is chosen',
      (tester) async {
    var pickCalls = 0;
    var dispatchCalls = 0;
    await pumpLauncher(
      tester,
      pickPhoto: (source) async {
        pickCalls++;
        return null;
      },
      dispatch: (image, mode) async => dispatchCalls++,
    );

    expect(find.text('拍照识题'), findsOneWidget);
    expect(find.text('仅拍照，不识别'), findsOneWidget);
    expect(find.text('拍照后进入「确认照片与识别模式」'), findsOneWidget);
    expect(pickCalls, 0);
    expect(dispatchCalls, 0);

    await tester.tap(
      find.byKey(const ValueKey<String>('photo-gallery-action')),
    );
    await tester.pumpAndSettle();

    expect(pickCalls, 1);
    expect(dispatchCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('captured photo waits for explicit CTA and defaults to OCR',
      (tester) async {
    var dispatchCalls = 0;
    ImportParseMode? dispatchedMode;
    await pumpLauncher(
      tester,
      pickPhoto: (source) async {
        expect(source, ImageSource.camera);
        return syntheticPhoto(syntheticPng);
      },
      dispatch: (image, mode) async {
        dispatchCalls++;
        dispatchedMode = mode;
      },
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('photo-shutter-action')),
    );
    await tester.pumpAndSettle();

    expect(find.byType(PhotoRecognitionConfirmationScreen), findsOneWidget);
    expect(find.text('确认照片'), findsOneWidget);
    expect(find.text('OCR'), findsOneWidget);
    expect(find.text('多模态'), findsOneWidget);
    expect(dispatchCalls, 0);
    final preview = tester.widget<Image>(
      find.descendant(
        of: find.byType(PhotoRecognitionConfirmationScreen),
        matching: find.byType(Image),
      ),
    );
    final resizedPreview = preview.image as ResizeImage;
    expect(resizedPreview.width, 1440);
    expect(resizedPreview.height, 1440);
    expect(resizedPreview.policy, ResizeImagePolicy.fit);

    await tester.tap(
      find.byKey(
        const ValueKey<String>('photo-start-recognition-action'),
      ),
    );
    await tester.pumpAndSettle();

    expect(dispatchCalls, 1);
    expect(dispatchedMode, ImportParseMode.ocr);
    expect(find.byKey(const ValueKey<String>('open-photo-capture')),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('vision mode is purple-themed and dispatches only after CTA',
      (tester) async {
    var dispatchCalls = 0;
    ImportParseMode? dispatchedMode;
    await pumpLauncher(
      tester,
      theme: AppTheme.darkTheme,
      pickPhoto: (source) async => syntheticPhoto(syntheticPng),
      dispatch: (image, mode) async {
        dispatchCalls++;
        dispatchedMode = mode;
      },
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('photo-gallery-action')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('photo-mode-vision')),
    );
    await tester.pump();

    final visionMaterial = tester.widget<Material>(
      find
          .descendant(
            of: find.byKey(const ValueKey<String>('photo-mode-vision')),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(
      visionMaterial.color,
      AppTheme.darkTheme.colorScheme.secondary.withValues(alpha: 0.12),
    );
    expect(dispatchCalls, 0);
    await tester.tap(
      find.byKey(
        const ValueKey<String>('photo-start-recognition-action'),
      ),
    );
    await tester.pumpAndSettle();

    expect(dispatchCalls, 1);
    expect(dispatchedMode, ImportParseMode.vision);
    expect(tester.takeException(), isNull);
  });
}
