import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart' as p;

void main() async {
  sqfliteFfiInit();
  var databaseFactory = databaseFactoryFfi;
  
  final dbPath = r'c:\Users\34331\shiroha_quiz\.dart_tool\sqflite_common_ffi\databases\shiroha_core_v1.db';
  
  print('Checking database at: $dbPath');
  if (!File(dbPath).existsSync()) {
    print('Database file does not exist at $dbPath');
    return;
  }
  
  final db = await databaseFactory.openDatabase(dbPath);
  
  print('\n=== QUERYING 5 QUESTIONS ===');
  final List<Map<String, dynamic>> questions = await db.query(
    'questions',
    limit: 5,
  );
  
  for (var q in questions) {
    print('-------------------------------------');
    print('ID: ${q['id']}');
    print('Type: ${q['type']}');
    print('Bank Name: ${q['bank_name']}');
    print('Content: ${q['content']}');
    print('Options: ${q['options']}');
    print('Standard Answer: ${q['standard_answer']}');
    print('Explanation: ${q['explanation']}');
  }
  
  await db.close();
}
