// Test-only delivery of public data and original framed bytes.
import 'dart:io';
import 'package:path/path.dart' as p;

Future<File> waitPublicFile(Directory root, String name) async {
  final file = File(p.join(root.path, name));
  final watch = Stopwatch()..start();
  while (!await file.exists()) {
    if (watch.elapsed > const Duration(seconds: 40)) {
      throw StateError('Public fixture delivery timed out: $name');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return file;
}

Future<void> publishPublic(Directory root, String name, List<int> bytes) async {
  final temp = File(p.join(root.path, '$name.writing'));
  await temp.writeAsBytes(bytes, flush: true);
  await temp.rename(p.join(root.path, name));
}
