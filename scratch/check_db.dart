import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';

void main() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  // 猜测数据库路径
  // 根据 Flutter 默认的 getApplicationDocumentsDirectory()
  String dbPath = '';
  if (Platform.isWindows) {
    dbPath = join(Platform.environment['USERPROFILE']!, 'Documents', 'shiroha_quiz.db');
  }
  
  // 或者也许在 AppData/Roaming/com.example/shiroha_quiz 里面？
  // flutter desktop usually puts documents in Documents.
  // 实际上 databaseFactory.getDatabasesPath() 可能不同。
  
  print('Trying to locate database...');
  final defaultPath = await databaseFactory.getDatabasesPath();
  final fullPath = join(defaultPath, 'shiroha_quiz.db');
  print('Path: $fullPath');
  
  if (!File(fullPath).existsSync()) {
    print('Database not found at $fullPath');
    return;
  }

  final db = await databaseFactory.openDatabase(fullPath);
  final res = await db.query('ai_engines', where: 'is_active = 1 AND engine_type = ?', whereArgs: ['text']);
  print('Active Text Engine:');
  for (var row in res) {
    print(row);
  }
  await db.close();
}
