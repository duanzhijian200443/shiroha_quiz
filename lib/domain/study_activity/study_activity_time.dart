/// Persistence-ready confirmed facts; duration is supplied by monotonic elapsed,
/// never reconstructed from event timestamps or learning/queue payloads.
final class StudyActivitySegmentDraft {
  StudyActivitySegmentDraft({
    required this.sequence,
    required this.localDate,
    required this.utcOffsetMinutes,
    required this.startUtcMs,
    required this.endUtcMs,
    required this.durationMs,
  }) {
    _require(sequence > 0 && isStudyActivityLocalDate(localDate));
    _require(startUtcMs >= 0 && endUtcMs >= startUtcMs && durationMs >= 0);
    _utc(startUtcMs);
    _utc(endUtcMs);
  }

  final int sequence;
  final String localDate;
  final int utcOffsetMinutes;
  final int startUtcMs;
  final int endUtcMs;
  final int durationMs;
}

/// Captured calendar rules, without a zone ID or platform dependency.
/// Implementations must remain immutable after capture. Bounds are actual UTC
/// conversions of local midnight or an offset transition, whichever comes first;
/// offset and local date must be constant throughout each half-open interval.
abstract interface class StudyActivityLocalTimeMapping {
  StudyActivityLocalInterval intervalAt(int utcMs);
}

final class StudyActivityLocalInterval {
  StudyActivityLocalInterval({
    required this.localDate,
    required this.utcOffsetMinutes,
    required this.startUtcMs,
    required this.endUtcMs,
  }) {
    _require(isStudyActivityLocalDate(localDate) && endUtcMs > startUtcMs);
    _utc(startUtcMs);
    _utc(endUtcMs);
  }

  final String localDate;
  final int utcOffsetMinutes;
  final int startUtcMs;
  final int endUtcMs;
}

/// Projects confirmed monotonic duration forward from its last wall anchor using
/// that anchor's captured mapping. Actual local bounds handle multi-day/DST
/// splits; a newly observed wall/zone mapping never reattributes this interval.
/// Zero elapsed validates the anchor but emits no learning-day fact.
List<StudyActivitySegmentDraft> splitStudyActivityElapsed({
  required int startUtcMs,
  required int durationMs,
  required int firstSequence,
  required StudyActivityLocalTimeMapping mapping,
}) {
  try {
    _require(startUtcMs >= 0 && durationMs >= 0 && firstSequence > 0);
    final endUtcMs = startUtcMs + durationMs;
    _require(endUtcMs >= startUtcMs);
    _utc(startUtcMs);
    _utc(endUtcMs);
    var cursor = startUtcMs;
    final drafts = <StudyActivitySegmentDraft>[];
    do {
      final interval = mapping.intervalAt(cursor);
      _require(interval.startUtcMs <= cursor && cursor < interval.endUtcMs);
      // Check supplied attribution rather than guessing a midnight with the
      // current offset. The mapping must split offset changes explicitly.
      _require(
          _localDate(cursor, interval.utcOffsetMinutes) == interval.localDate);
      final until = endUtcMs < interval.endUtcMs ? endUtcMs : interval.endUtcMs;
      if (until > cursor) {
        _require(_localDate(until - 1, interval.utcOffsetMinutes) ==
            interval.localDate);
        drafts.add(StudyActivitySegmentDraft(
          sequence: firstSequence + drafts.length,
          localDate: interval.localDate,
          utcOffsetMinutes: interval.utcOffsetMinutes,
          startUtcMs: cursor,
          endUtcMs: until,
          durationMs: until - cursor,
        ));
      }
      cursor = until;
    } while (cursor < endUtcMs);
    _require(drafts.fold<int>(0, (sum, draft) => sum + draft.durationMs) ==
        durationMs);
    return List.unmodifiable(drafts);
  } catch (_) {
    // Calendar adapters can fail; rejected inputs/causes never leave this seam.
    throw const FormatException('Unavailable StudyActivity time attribution.');
  }
}

bool isStudyActivityLocalDate(String value) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
  final year = int.parse(value.substring(0, 4));
  final month = int.parse(value.substring(5, 7));
  final day = int.parse(value.substring(8, 10));
  final date = DateTime.utc(year, month, day);
  return date.year == year && date.month == month && date.day == day;
}

String _localDate(int utcMs, int offset) {
  final date = _utc(utcMs + offset * Duration.millisecondsPerMinute);
  return '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}

DateTime _utc(int value) =>
    DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);

void _require(bool valid) {
  if (!valid) throw const FormatException('Invalid StudyActivity time facts.');
}
