import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../tool/mcp_vnext_windows_app_smoke.dart' as smoke;
import '../../tool/ui_rwd_driver.dart';

void main() {
  test('each Driver launch receives fresh owned temporary storage', () {
    final first = createUiRwdDriverPaths();
    final second = createUiRwdDriverPaths();
    final roots = [
      Directory(first.applicationSupportRoot),
      Directory(second.applicationSupportRoot),
    ];
    for (final root in roots) {
      expect(
          p.equals(p.dirname(root.path),
              Directory.systemTemp.resolveSymbolicLinksSync()),
          isTrue);
      expect(p.basename(root.path), startsWith(smoke.smokePrefix));
      expect(File(p.join(root.path, '.smoke-owner')).readAsStringSync(),
          smoke.smokeOwner);
      addTearDown(() => root.delete(recursive: true));
    }
    expect(first.databasePath, isNot(second.databasePath));
    expect(File(first.databasePath).existsSync(), isFalse);
    expect(File(second.databasePath).existsSync(), isFalse);
  });
}
