import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_driver/driver_extension.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/core/app_data_paths.dart';
import 'package:shiroha_quiz/main.dart' as app;

import 'mcp_vnext_windows_app_smoke.dart' as smoke;

/// Fresh task-owned storage for an explicitly launched UI validation process.
/// No caller-supplied path or existing application data can be adopted.
AppDataPaths createUiRwdDriverPaths() {
  final root =
      Directory.systemTemp.createTempSync('${smoke.smokePrefix}ui_rwd_');
  File(p.join(root.path, '.smoke-owner')).writeAsStringSync(smoke.smokeOwner);
  return smoke.smokeDataPaths(root.path);
}

class _MetricsObserver extends WidgetsBindingObserver {
  @override
  void didChangeMetrics() {
    WidgetsBinding.instance.addPostFrameCallback((_) => report());
  }

  void report() {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final logical = view.physicalSize / view.devicePixelRatio;
    debugPrint('UI_RWD_METRICS width=${logical.width} height=${logical.height} '
        'dpr=${view.devicePixelRatio} physical=${view.physicalSize}');
  }
}

/// Debug-only Flutter Driver entry; normal main() never enables this extension.
void main() {
  if (!kDebugMode) throw StateError('UI validation requires a Debug build');
  final paths = createUiRwdDriverPaths();
  HttpOverrides.global = smoke.SmokeHttpOverrides();
  enableFlutterDriverExtension();
  final metrics = _MetricsObserver();
  WidgetsBinding.instance.addObserver(metrics);
  WidgetsBinding.instance.addPostFrameCallback((_) => metrics.report());
  app.runShirohaQuiz(
      dataPaths: paths, createCredentialStore: smoke.SmokeCredentialStore.new);
}
