import 'dart:convert';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart';

void main() async {
  sqfliteFfiInit();
  final dbFactory = databaseFactoryFfi;
  final dbPath = await dbFactory.getDatabasesPath();
  final path = join(dbPath, 'shiroha_core_v1.db');
  
  final db = await dbFactory.openDatabase(path);
  
  final List<Map<String, dynamic>> tasks = await db.rawQuery(
    "SELECT id, title, parsed_data FROM import_tasks WHERE parsed_data IS NOT NULL"
  );
  
  for (var t in tasks) {
    String parsedData = t['parsed_data'] as String;
    if (parsedData.contains('a_0') || parsedData.contains('b_0') || parsedData.contains('xi') || parsedData.contains('XI')) {
      print('========================================');
      print('TASK ID: ${t['id']}, TITLE: ${t['title']}');
      try {
        final List<dynamic> list = jsonDecode(parsedData);
        for (int i = 0; i < list.length; i++) {
          final q = list[i];
          final qStr = jsonEncode(q);
          if (qStr.contains('a_0') || qStr.contains('b_0') || qStr.contains('xi') || qStr.contains('XI')) {
            print('Question index $i (Q_NUM: ${q['q_num']}):');
            print('CONTENT:');
            print(q['content']);
            print('ANSWER:');
            print(q['standard_answer']);
            print('EXPLANATION:');
            print(q['explanation']);
          }
        }
      } catch (e) {
        print('Error: $e');
      }
    }
  }
  
  await db.close();
}
