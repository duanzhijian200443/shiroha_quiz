import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

/// Removes only the exact authorized R7 amendment before the retained R2/R3
/// hashes and prior P7 projection run. No ignored region or new baseline hash.
String retainedR6RuntimeSource(String path, String source) {
  final amendments = jsonDecode(
      File('test/application/modules/fixtures/r7_runtime_additions.json')
          .readAsStringSync()) as Map;
  final operations = amendments[path] as List?;
  if (operations == null) return source;
  expect(operations, isNotEmpty);
  for (final raw in operations.reversed) {
    final op = raw as Map;
    expect(op.keys.toSet(), {'before', 'after', 'count'});
    final before = op['before'] as String;
    final after = op['after'] as String;
    expect(before, isNotEmpty);
    expect(after, isNotEmpty);
    expect(op['count'], 1);
    expect(source.split(after).length - 1, 1,
        reason: 'Missing/changed/duplicated exact R7 amendment: $path');
    source = source.replaceAll(after, before);
  }
  return source;
}
