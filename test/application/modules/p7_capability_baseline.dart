import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

/// Exact P7 source amendment projection, retaining the original R2 hash.
/// No ignored region, wildcard replacement or replacement baseline hash.
String retainedR2CapabilitySource(String path, String source) {
  if (path != 'lib/application/capabilities/capability.dart') return source;
  final operations = jsonDecode(
      File('test/application/modules/fixtures/p7_capability_additions.json')
          .readAsStringSync()) as List;
  expect(operations, isNotEmpty);
  for (final raw in operations.reversed) {
    final op = raw as Map;
    expect(op.keys.toSet(), {'before', 'after', 'count'});
    final before = op['before'] as String;
    final after = op['after'] as String;
    final count = op['count'] as int;
    expect(before, isNotEmpty);
    expect(after, isNotEmpty);
    expect(count, 1);
    expect(source.split(after).length - 1, count,
        reason: 'Missing/changed/duplicated exact P7 amendment: $path');
    source = source.replaceAll(after, before);
  }
  return source;
}
