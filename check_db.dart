import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() async {
  sqfliteFfiInit();
  var databaseFactory = databaseFactoryFfi;

  // Find the database path
  String dbPath = 'shiroha_core_v1.db';
  if (Platform.isWindows) {
    dbPath =
        '${Platform.environment['USERPROFILE']}\\.dart_tool\\sqflite_common_ffi\\databases\\shiroha_core_v1.db';
  }

  print('Checking database at: $dbPath');
  if (!File(dbPath).existsSync()) {
    print('Database file does not exist at this path.');

    // Also check AppData
    String appDataPath =
        '${Platform.environment['APPDATA']}\\com.example.shiroha_quiz\\shiroha_core_v1.db';
    print('Checking AppData path: $appDataPath');
    if (File(appDataPath).existsSync()) {
      dbPath = appDataPath;
    } else {
      // Check local app data
      String localPath =
          '${Platform.environment['LOCALAPPDATA']}\\Packages\\com.example.shiroha_quiz_g22vhbktks9hy\\LocalState\\databases\\shiroha_core_v1.db';
      print('Checking LocalAppData path: $localPath');
      if (File(localPath).existsSync()) {
        dbPath = localPath;
      }
    }
  }

  try {
    var db = await databaseFactory.openDatabase(dbPath);
    var count = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM questions'));
    print('Total questions: $count');

    var banks = await db.rawQuery(
        'SELECT bank_name, COUNT(*) as c FROM questions GROUP BY bank_name');
    print('Banks:');
    for (var b in banks) {
      print('  ${b['bank_name']}: ${b['c']}');
    }

    var banksTable = await db.rawQuery('SELECT * FROM banks');
    print('Banks Table:');
    for (var b in banksTable) {
      print('  ${b['name']} (folder: ${b['folder_name']})');
    }

    await db.close();
  } catch (e) {
    print('Error: $e');
  }
}
