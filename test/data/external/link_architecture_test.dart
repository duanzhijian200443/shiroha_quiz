import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
      'Link and frontend transitive repository closure cannot initialize Flutter or SQLite',
      () {
    final visited = <String>{};
    final pending = ['tool/link/link.dart', 'tool/link/frontend.dart'];
    while (pending.isNotEmpty) {
      final path = p.normalize(pending.removeLast());
      if (!visited.add(path)) continue;
      final source = File(path).readAsStringSync();
      expect(source, isNot(contains('DatabaseHelper')), reason: path);
      expect(source, isNot(contains('package:sqflite')), reason: path);
      expect(source, isNot(contains('package:flutter/')), reason: path);
      expect(source, isNot(contains('pubspec.yaml')), reason: path);
      for (final match in RegExp(r'''(?:import|export)\s+['"]([^'"]+)['"]''')
          .allMatches(source)) {
        final uri = match[1]!;
        if (uri.startsWith('package:shiroha_quiz/')) {
          pending.add(
              p.join('lib', uri.substring('package:shiroha_quiz/'.length)));
        } else if (!uri.contains(':')) {
          pending.add(p.join(p.dirname(path), uri));
        }
      }
    }
    expect(visited, contains(p.normalize('lib/mcp/vnext_mcp_server.dart')));
    expect(visited, isNot(contains(p.normalize('lib/main.dart'))));
  });
  test('Android-only builder never requires or builds a Windows Shiroha App',
      () {
    final script = File('tool/link/build_runtime.ps1').readAsStringSync();
    expect(script, isNot(contains('flutter build windows')));
    expect(script, isNot(contains('shiroha_quiz.exe')));
    expect(script, contains('IncludeWindowsClient'));
  });
}
