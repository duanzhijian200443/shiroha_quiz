import '../../application/study_query/study_query_dtos.dart';
import '../../application/study_query/study_query_error.dart';
import '../../application/study_query/study_query_time_zone.dart';

/// Today-only resolver using the operating system's current local zone.
/// Constructing local midnight uses the offset at midnight, including DST.
/// The default T0 IANA resolver and Agent/MCP timezone contracts stay intact.
final class SystemLocalStudyTimeZone implements StudyQueryTimeZone {
  const SystemLocalStudyTimeZone();
  static const zoneName = 'local';

  void _validate(String name) {
    if (name != zoneName) {
      throw const StudyQueryException(StudyQueryFailure.invalidRequest);
    }
  }

  @override
  StudyLocalDate localDateOf(DateTime utcInstant, String ianaName) {
    _validate(ianaName);
    final local = utcInstant.toLocal();
    return StudyLocalDate(year: local.year, month: local.month, day: local.day);
  }

  @override
  DateTime utcInstantOfLocalMidnight(StudyLocalDate date, String ianaName) {
    _validate(ianaName);
    return DateTime(date.year, date.month, date.day).toUtc();
  }
}
