import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/core/observability/app_logger.dart';
import 'package:shiroha_quiz/core/observability/log_record.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_table_projection.dart';

final class _MemoryLogSink implements LogSink {
  final List<LogRecord> records = <LogRecord>[];

  @override
  Future<void> write(LogRecord record) async {
    records.add(record);
  }

  @override
  Future<void> flush() async {}
}

void main() {
  test('table rejection subtypes are fixed and never leak table input',
      () async {
    final sink = _MemoryLogSink();
    AppLogger.setSink(sink);
    addTearDown(() => AppLogger.setSink(null));

    Future<void> expectRejected(String html, String expectedSubtype) async {
      sink.records.clear();
      final result = OcrTableProjector.parseHtmlTable(
        html,
        sourceRef: SourceRef.document(sourceId: 'table_telemetry_fixture'),
      );
      expect(result, isNull);
      await AppLogger.flush();

      final records = sink.records
          .where((record) => record.data['stage'] == 'table_projection')
          .toList(growable: false);
      expect(records, hasLength(1));
      final record = records.single;
      expect(record.data['status'], 'rejected');
      expect(record.data['tableProjectionSubtype'], expectedSubtype);
      expect(record.data['count'], 1);
      final serialized = record.toJson().toString();
      expect(serialized, isNot(contains('cdn.example.com')));
      expect(serialized, isNot(contains('token=secret')));
      expect(serialized, isNot(contains('private table sentinel')));
      expect(serialized, isNot(contains('private table cell sentinel')));
    }

    await expectRejected(
      '${List<String>.filled(
        OcrTableProjector.maxInputLength + 1,
        'x',
      ).join()} private table sentinel',
      'input_too_large',
    );
    await expectRejected(
      '<div>private table sentinel</div>',
      'table_missing',
    );
    await expectRejected(
      '<table><tr><td><img src="https://cdn.example.com/private/path.png?token=secret">private table sentinel</td></tr></table>',
      'unsafe_markup',
    );
    await expectRejected(
      '<table>private table sentinel</table>',
      'rows_missing',
    );
    await expectRejected(
      '<table>${List<String>.filled(OcrTableProjector.maxRowCount + 1, '<tr><td>x</td></tr>').join()}</table>',
      'row_limit',
    );
    await expectRejected(
      '<table><tr>private table sentinel</tr></table>',
      'cells_missing',
    );
    await expectRejected(
      '<table><tr>${List<String>.filled(OcrTableProjector.maxColumnCount + 1, '<td>x</td>').join()}</tr></table>',
      'column_limit',
    );
    await expectRejected(
      '<table><tr><td rowspan="2">private table cell sentinel</td></tr></table>',
      'merged_cell_geometry',
    );
    await expectRejected(
      '<table><tr><td>${List<String>.filled(4097, 'x').join()}</td></tr></table>',
      'source_table_invalid',
    );

    sink.records.clear();
    final accepted = OcrTableProjector.parseHtmlTable(
      '<table><tr><td>stable</td></tr></table>',
      sourceRef: SourceRef.document(sourceId: 'table_telemetry_fixture'),
    );
    await AppLogger.flush();
    expect(accepted, isA<SourceTablePart>());
    expect(
      sink.records.where(
        (record) => record.data['stage'] == 'table_projection',
      ),
      isEmpty,
    );
  });
}
