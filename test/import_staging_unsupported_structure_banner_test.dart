import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiroha_quiz/data/models/question_draft.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_diagnostic_formatter.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_diagnostic_message.dart';
import 'package:shiroha_quiz/services/import_pipeline/subjective_answer_distillation_service.dart';
import 'package:shiroha_quiz/ui/pages/import_staging_screen.dart';

class _MockRepo implements QuestionRepository {
  @override
  Future<void> saveQuestionDraftsToBank({
    required String bankName,
    String? folderName,
    required List<dynamic> questions,
  }) async {}

  @override
  Future<List<String>> getAvailableFolders() async => [];

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakeDistiller implements SubjectiveAnswerDistiller {
  int callCount = 0;

  @override
  Future<SubjectiveAnswerDistillationResult> distill({
    required int questionNumber,
    required QuestionDraft question,
    required bool isStemOnly,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    callCount++;
    return const SubjectiveAnswerDistillationResult.applied('Synthetic');
  }
}

const _imageMessage = '检测到图片内容，但当前版本尚不能显示原图，请对照 PDF 校对。';
const _tableMessage = '检测到表格内容，当前可能以文本或 HTML 片段显示，请对照 PDF 校对。';
const _bothMessage = '检测到图片和表格内容，当前版本尚不能完整呈现，请对照 PDF 校对。';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('ImportDiagnosticFormatter unsupported structure summary', () {
    List<ImportDiagnosticMessage> formatWith(
      Map<String, dynamic> diagnostics,
    ) {
      return ImportDiagnosticFormatter.format(diagnostics: diagnostics);
    }

    test('images only produce one safe image warning', () {
      final messages = formatWith({
        'unsupportedStructureSummary': {
          'imageBlockCount': 2,
          'tableBlockCount': 0,
        },
      });

      expect(messages, hasLength(1));
      expect(messages.single.severity, ImportDiagnosticSeverity.warning);
      expect(messages.single.title, '图片暂未完整导入');
      expect(messages.single.message, contains('2 个图片或图形区域'));
      expect(messages.single.message, contains('请对照原 PDF 校对相关题目'));
      expect(messages.single.code, 'UNSUPPORTED_IMAGE_BLOCKS');
    });

    test('tables only produce one safe table warning', () {
      final messages = formatWith({
        'unsupportedStructureSummary': {
          'imageBlockCount': 0,
          'tableBlockCount': 3,
        },
      });

      expect(messages, hasLength(1));
      expect(messages.single.severity, ImportDiagnosticSeverity.warning);
      expect(messages.single.title, '表格暂未结构化');
      expect(messages.single.message, contains('3 个表格区域'));
      expect(messages.single.message, contains('请对照原 PDF 校对'));
      expect(messages.single.code, 'UNSUPPORTED_TABLE_BLOCKS');
    });

    test('images and tables produce exactly one warning per type', () {
      final messages = formatWith({
        'unsupportedStructureSummary': {
          'imageBlockCount': 1,
          'tableBlockCount': 4,
        },
      });

      expect(messages, hasLength(2));
      expect(
        messages.map((m) => m.title).toList(),
        containsAll(<String>['图片暂未完整导入', '表格暂未结构化']),
      );
    });

    test('zero counts produce no warnings', () {
      final messages = formatWith({
        'unsupportedStructureSummary': {
          'imageBlockCount': 0,
          'tableBlockCount': 0,
        },
      });

      expect(messages, isEmpty);
    });

    test('negative counts are safely ignored', () {
      final messages = formatWith({
        'unsupportedStructureSummary': {
          'imageBlockCount': -2,
          'tableBlockCount': -1,
        },
      });

      expect(messages, isEmpty);
    });

    test('string counts are safely ignored', () {
      final messages = formatWith({
        'unsupportedStructureSummary': {
          'imageBlockCount': '2',
          'tableBlockCount': '1',
        },
      });

      expect(messages, isEmpty);
    });

    test('non-map summary values are safely ignored', () {
      final messages = formatWith({
        'unsupportedStructureSummary': 'corrupted',
      });

      expect(messages, isEmpty);
    });

    test('warnings never leak synthetic private text or identifiers', () {
      final messages = formatWith({
        'unsupportedStructureSummary': {
          'imageBlockCount': 2,
          'tableBlockCount': 1,
        },
        'synthetic_canary': 'PRIVATE_CANARY_TEXT_9f3a',
      });
      final joined =
          messages.map((m) => '${m.title} ${m.message} ${m.source}').join();

      expect(joined, isNot(contains('PRIVATE_CANARY_TEXT_9f3a')));
      expect(joined, isNot(contains('blockId')));
      expect(joined, isNot(contains('bbox')));
    });
  });

  group('ImportStagingScreen unsupported structure banner', () {
    Widget createWidget({
      required Map<String, dynamic>? diagnostics,
      List<Map<String, dynamic>>? questions,
      SubjectiveAnswerDistiller? distiller,
    }) {
      return MaterialApp(
        home: ImportStagingScreen(
          parsedQuestions: questions ??
              const [
                {
                  'q_num': 1,
                  'question_type': 0,
                  'content': 'Normal question',
                  'options': ['A', 'B'],
                  'standard_answer': 'A',
                },
              ],
          diagnostics: diagnostics,
          questionRepository: _MockRepo(),
          answerDistiller: distiller,
        ),
      );
    }

    testWidgets('shows image-only banner', (WidgetTester tester) async {
      await tester.pumpWidget(createWidget(diagnostics: {
        'unsupportedStructureSummary': {
          'imageBlockCount': 2,
          'tableBlockCount': 0,
        },
      }));
      await tester.pumpAndSettle();

      expect(find.text(_imageMessage), findsOneWidget);
      expect(find.text(_tableMessage), findsNothing);
      expect(find.text(_bothMessage), findsNothing);
    });

    testWidgets('shows table-only banner', (WidgetTester tester) async {
      await tester.pumpWidget(createWidget(diagnostics: {
        'unsupportedStructureSummary': {
          'imageBlockCount': 0,
          'tableBlockCount': 1,
        },
      }));
      await tester.pumpAndSettle();

      expect(find.text(_tableMessage), findsOneWidget);
      expect(find.text(_imageMessage), findsNothing);
      expect(find.text(_bothMessage), findsNothing);
    });

    testWidgets('shows combined image and table banner',
        (WidgetTester tester) async {
      await tester.pumpWidget(createWidget(diagnostics: {
        'unsupportedStructureSummary': {
          'imageBlockCount': 1,
          'tableBlockCount': 3,
        },
      }));
      await tester.pumpAndSettle();

      expect(find.text(_bothMessage), findsOneWidget);
      expect(find.text(_imageMessage), findsNothing);
      expect(find.text(_tableMessage), findsNothing);
    });

    testWidgets('no banner when summary is missing',
        (WidgetTester tester) async {
      await tester.pumpWidget(createWidget(diagnostics: {}));
      await tester.pumpAndSettle();

      expect(find.text(_imageMessage), findsNothing);
      expect(find.text(_tableMessage), findsNothing);
      expect(find.text(_bothMessage), findsNothing);
    });

    testWidgets('no banner and no crash for malformed summary',
        (WidgetTester tester) async {
      await tester.pumpWidget(createWidget(diagnostics: {
        'unsupportedStructureSummary': {
          'imageBlockCount': '2',
          'tableBlockCount': -1,
        },
      }));
      await tester.pumpAndSettle();

      expect(find.text(_imageMessage), findsNothing);
      expect(find.text(_tableMessage), findsNothing);
      expect(find.text(_bothMessage), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(createWidget(diagnostics: {
        'unsupportedStructureSummary': 'corrupted',
      }));
      await tester.pumpAndSettle();

      expect(find.text(_imageMessage), findsNothing);
      expect(find.text(_bothMessage), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('banner does not block confirm-into-bank logic',
        (WidgetTester tester) async {
      await tester.pumpWidget(createWidget(diagnostics: {
        'unsupportedStructureSummary': {
          'imageBlockCount': 1,
          'tableBlockCount': 1,
        },
      }));
      await tester.pumpAndSettle();

      final elevatedButton = find.byType(ElevatedButton);
      final buttonWidget = tester.widget<ElevatedButton>(elevatedButton);
      expect(buttonWidget.onPressed, isNotNull,
          reason: 'unsupported structure banner must not block save');
    });

    testWidgets('explanation switch keeps title and new subtitle',
        (WidgetTester tester) async {
      await tester.pumpWidget(createWidget(diagnostics: {}));
      await tester.pumpAndSettle();

      expect(find.text('同时导入选择题、填空题解析'), findsOneWidget);
      expect(
        find.text('开启后保留选择题和填空题的已识别解析，可能增加需要校对的内容。'),
        findsOneWidget,
      );
      expect(
        find.textContaining('可能增加校对问题和 AI 处理时间'),
        findsNothing,
      );
    });

    testWidgets('toggling explanation switch does not call answer distiller',
        (WidgetTester tester) async {
      final distiller = _FakeDistiller();
      await tester.pumpWidget(createWidget(
        diagnostics: {},
        distiller: distiller,
      ));
      await tester.pumpAndSettle();

      final switchFinder =
          find.byKey(const ValueKey('objective-explanation-document-switch'));
      final before = tester.widget<SwitchListTile>(switchFinder).value;

      await tester.tap(switchFinder);
      await tester.pumpAndSettle();

      final after = tester.widget<SwitchListTile>(switchFinder).value;
      expect(after, isNot(before),
          reason: 'switch must change explanation retention strategy');
      expect(distiller.callCount, 0,
          reason: 'retention switch must never call the answer distiller');
      expect(tester.takeException(), isNull);
    });
  });
}
