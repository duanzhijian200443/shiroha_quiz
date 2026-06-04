import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart' as p;
import 'dart:io';
import '../lib/services/ai_service.dart';
import '../lib/core/database/database_helper.dart';

void main() {
  test('Run Vision Parsing test on Pages 15 to 19', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    final tempDir = Directory.systemTemp.path;
    final activeEngine =
        await DatabaseHelper.instance.getActiveAiEngine('vision');
    print('Active Vision Engine: $activeEngine');

    if (activeEngine == null) {
      print('No active vision engine found in DB!');
      return;
    }

    for (int pageNum = 15; pageNum <= 19; pageNum++) {
      final pagePath = p.join(tempDir, 'file_0_page_$pageNum.jpg');
      print('\n--- Parsing Page $pageNum ($pagePath) ---');
      if (!File(pagePath).existsSync()) {
        print('File does not exist');
        continue;
      }
      try {
        final result =
            await AiService.instance.parseImagesWithVision([pagePath]);
        print('Page $pageNum Parsed Questions Count: ${result.length}');
        for (var q in result) {
          print('  q_num: ${q['q_num']} | type: ${q['type']}');
          print('  content: "${q['content']}"');
          print('  standard_answer: "${q['standard_answer']}"');
          print('  explanation: "${q['explanation']}"');
        }
      } catch (e) {
        print('Failed to parse Page $pageNum: $e');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
