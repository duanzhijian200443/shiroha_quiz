import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('Android-only AOT roots have no Windows App or database dependency', () {
    final seen = <String>{};
    final queue = [
      'tool/link/link.dart',
      'tool/link/control.dart',
      'tool/link/frontend.dart'
    ];
    final imports = RegExp(r'''(?:import|export)\s+['"]([^'"]+)['"]''');
    while (queue.isNotEmpty) {
      final path = p.normalize(queue.removeLast());
      if (!seen.add(path)) continue;
      final source = File(path).readAsStringSync();
      expect(source, isNot(contains('DatabaseHelper')), reason: path);
      expect(source, isNot(contains('package:sqflite')), reason: path);
      expect(source, isNot(contains('package:flutter/')), reason: path);
      for (final match in imports.allMatches(source)) {
        final uri = match.group(1)!;
        if (uri.startsWith('package:shiroha_quiz/')) {
          queue.add('lib/${uri.substring('package:shiroha_quiz/'.length)}');
        } else if (!uri.contains(':')) {
          queue.add(p.join(p.dirname(path), uri));
        }
      }
    }
    expect(seen, isNot(contains(p.normalize('lib/main.dart'))));
    final installer =
        File('tool/link/configure_installation.ps1').readAsStringSync();
    expect(installer, isNot(contains('RELEASED')));
    expect(installer, isNot(contains('Remove-Item')));
    final build = File('tool/link/build_runtime.ps1').readAsStringSync();
    expect(build, isNot(contains('shiroha_quiz.exe')));
    expect(build, isNot(contains('IncludeWindowsClient')));
  });

  test(
      'native Link admission precedes initialization and model controls are separate',
      () {
    final entry = File('tool/link/link.dart').readAsStringSync();
    expect(entry.indexOf('openLinkBusiness'),
        lessThan(entry.indexOf('LinkInitialization(config)')));
    final frontend = File('lib/mcp/link_frontend.dart').readAsStringSync();
    for (final forbidden in [
      'LinkInitialization',
      'openLinkControl',
      'SlotOwnershipStore',
      'device.dpapi'
    ]) {
      expect(frontend, isNot(contains(forbidden)));
    }
    final runtime =
        File('lib/data/external/link/link_runtime.dart').readAsStringSync();
    expect(runtime, isNot(contains('handoff.claim')));
    expect(runtime, isNot(contains('recover(')));
  });
}
