import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart';

void main() async {
  sqfliteFfiInit();
  var databaseFactory = databaseFactoryFfi;
  final dbPath = join(Directory.current.path, '.dart_tool', 'sqflite_common_ffi', 'databases', 'shiroha_quiz.db');
  
  if (!File(dbPath).existsSync()) {
      print('DB not found at $dbPath');
      // maybe check Windows standard path
      // the app uses getDatabasesPath() from sqflite.
      return;
  }
}
