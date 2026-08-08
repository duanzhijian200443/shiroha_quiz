// Embedded IANA timezone resolver unit tests (bounded DST subset).
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/study_query/study_query_dtos.dart';
import 'package:shiroha_quiz/application/study_query/study_query_error.dart';
import 'package:shiroha_quiz/application/study_query/study_query_time_zone.dart';

void main() {
  const resolver = EmbeddedIanaTimeZoneResolver();

  StudyLocalDate date(String iso, String zone) {
    return resolver.localDateOf(DateTime.parse(iso).toUtc(), zone);
  }

  group('fixed offset zones', () {
    test('UTC and Shanghai day boundaries', () {
      expect(date('2026-08-08T15:59:59Z', 'Asia/Shanghai'),
          const StudyLocalDate(year: 2026, month: 8, day: 8));
      expect(date('2026-08-08T16:00:00Z', 'Asia/Shanghai'),
          const StudyLocalDate(year: 2026, month: 8, day: 9));
      expect(date('2026-08-08T23:59:59Z', 'UTC'),
          const StudyLocalDate(year: 2026, month: 8, day: 8));
      expect(date('2026-08-09T00:00:00Z', 'UTC'),
          const StudyLocalDate(year: 2026, month: 8, day: 9));
    });

    test('half-hour offset zone (Asia/Kolkata)', () {
      expect(date('2026-01-01T18:29:59Z', 'Asia/Kolkata'),
          const StudyLocalDate(year: 2026, month: 1, day: 1));
      expect(date('2026-01-01T18:30:00Z', 'Asia/Kolkata'),
          const StudyLocalDate(year: 2026, month: 1, day: 2));
    });

    test('local midnight round trip', () {
      final midnight = resolver.utcInstantOfLocalMidnight(
        const StudyLocalDate(year: 2026, month: 8, day: 9),
        'Asia/Shanghai',
      );
      expect(midnight, DateTime.utc(2026, 8, 8, 16));
    });
  });

  group('DST rule zones', () {
    test('London BST transition is UTC-anchored', () {
      expect(date('2026-03-29T00:30:00Z', 'Europe/London'),
          const StudyLocalDate(year: 2026, month: 3, day: 29));
      expect(date('2026-03-29T01:30:00Z', 'Europe/London'),
          const StudyLocalDate(year: 2026, month: 3, day: 29));
      expect(date('2026-03-29T23:30:00Z', 'Europe/London'),
          const StudyLocalDate(year: 2026, month: 3, day: 30));
      expect(date('2026-10-25T00:30:00Z', 'Europe/London'),
          const StudyLocalDate(year: 2026, month: 10, day: 25));
    });

    test('New York EST/EDT day boundary', () {
      expect(date('2026-03-09T03:59:00Z', 'America/New_York'),
          const StudyLocalDate(year: 2026, month: 3, day: 8));
      expect(date('2026-03-09T04:01:00Z', 'America/New_York'),
          const StudyLocalDate(year: 2026, month: 3, day: 9));
      expect(date('2026-07-01T04:00:00Z', 'America/New_York'),
          const StudyLocalDate(year: 2026, month: 7, day: 1));
    });

    test('Sydney southern-hemisphere DST', () {
      expect(date('2026-01-15T00:00:00Z', 'Australia/Sydney'),
          const StudyLocalDate(year: 2026, month: 1, day: 15));
      expect(date('2026-07-15T00:00:00Z', 'Australia/Sydney'),
          const StudyLocalDate(year: 2026, month: 7, day: 15));
      // DST ends 2026-04-05 03:00 local (UTC 2026-04-04T16:00Z).
      expect(date('2026-04-04T12:00:00Z', 'Australia/Sydney'),
          const StudyLocalDate(year: 2026, month: 4, day: 4));
      expect(date('2026-04-04T15:59:59Z', 'Australia/Sydney'),
          const StudyLocalDate(year: 2026, month: 4, day: 5));
      expect(date('2026-04-05T05:00:00Z', 'Australia/Sydney'),
          const StudyLocalDate(year: 2026, month: 4, day: 5));
    });
  });

  group('validation', () {
    test('unknown and malformed zone names are invalid requests', () {
      for (final name in <String>[
        'Mars/Olympus_Mons',
        'UTC/Invalid',
        'not a zone!!',
        'Europe/',
      ]) {
        expect(
          () => resolver.localDateOf(DateTime.utc(2026, 1, 1), name),
          throwsA(
            isA<StudyQueryException>().having(
              (error) => error.failure,
              'failure',
              StudyQueryFailure.invalidRequest,
            ),
          ),
          reason: 'expected invalid request for $name',
        );
      }
    });

    test('empty and over-long names are rejected', () {
      expect(
        () => resolver.localDateOf(DateTime.utc(2026, 1, 1), '   '),
        throwsA(isA<StudyQueryException>()),
      );
      expect(
        () => resolver.localDateOf(
          DateTime.utc(2026, 1, 1),
          'A' * 65,
        ),
        throwsA(isA<StudyQueryException>()),
      );
    });
  });
}
