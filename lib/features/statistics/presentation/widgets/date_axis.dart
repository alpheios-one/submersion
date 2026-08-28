/// Tick selection for a date-valued chart x axis.
///
/// The older `TrendLineChart` plots `FlSpot(index, value)`, so a three-month
/// gap and a three-week gap render identically. Per-dive series cannot do that
/// and stay honest, so they plot real timestamps and need ticks chosen from the
/// span rather than from the point count (issue #299).
///
/// Deliberately free of Flutter and of locale: labels are formatted by the
/// widget, which has a BuildContext. This file only decides where ticks go.
library;

enum DateAxisGranularity { day, month, quarter, year }

class DateAxis {
  const DateAxis({
    required this.min,
    required this.max,
    required this.ticks,
    required this.granularity,
  });

  /// Lower bound, as `millisecondsSinceEpoch`, for fl_chart's `minX`.
  final double min;

  /// Upper bound, as `millisecondsSinceEpoch`, for fl_chart's `maxX`.
  final double max;

  /// Tick positions, strictly increasing and always inside the bounds.
  final List<DateTime> ticks;

  final DateAxisGranularity granularity;

  /// Chooses a granularity from the span, then walks ticks across it.
  ///
  /// A degenerate range (one dive, or several on one day) is widened to a day
  /// so fl_chart has a non-zero axis to draw.
  factory DateAxis.forRange(DateTime first, DateTime last) {
    final start = first;
    var end = last;
    if (!end.isAfter(start)) {
      end = start.add(const Duration(days: 1));
    }

    final days = end.difference(start).inDays;
    final granularity = days > 1095
        ? DateAxisGranularity.year
        : days > 365
        ? DateAxisGranularity.quarter
        : days > 60
        ? DateAxisGranularity.month
        : DateAxisGranularity.day;

    return DateAxis(
      min: start.millisecondsSinceEpoch.toDouble(),
      max: end.millisecondsSinceEpoch.toDouble(),
      ticks: _ticksFor(start, end, granularity),
      granularity: granularity,
    );
  }

  static List<DateTime> _ticksFor(
    DateTime start,
    DateTime end,
    DateAxisGranularity granularity,
  ) {
    final ticks = <DateTime>[];

    switch (granularity) {
      case DateAxisGranularity.year:
        for (var y = start.year; y <= end.year; y++) {
          final tick = DateTime.utc(y);
          if (!tick.isBefore(start) && !tick.isAfter(end)) ticks.add(tick);
        }
      case DateAxisGranularity.quarter:
        var cursor = DateTime.utc(start.year, ((start.month - 1) ~/ 3) * 3 + 1);
        while (!cursor.isAfter(end)) {
          if (!cursor.isBefore(start)) ticks.add(cursor);
          cursor = DateTime.utc(cursor.year, cursor.month + 3);
        }
      case DateAxisGranularity.month:
        var cursor = DateTime.utc(start.year, start.month);
        while (!cursor.isAfter(end)) {
          if (!cursor.isBefore(start)) ticks.add(cursor);
          cursor = DateTime.utc(cursor.year, cursor.month + 1);
        }
      case DateAxisGranularity.day:
        // Aim for about five labels rather than one per day.
        final span = end.difference(start).inDays;
        final step = span <= 5 ? 1 : (span / 5).ceil();
        var cursor = DateTime.utc(start.year, start.month, start.day);
        if (cursor.isBefore(start)) {
          cursor = cursor.add(const Duration(days: 1));
        }
        while (!cursor.isAfter(end)) {
          ticks.add(cursor);
          cursor = cursor.add(Duration(days: step));
        }
    }

    // A range narrower than one tick step would otherwise draw a bare axis.
    if (ticks.isEmpty) ticks.add(start);
    return List.unmodifiable(ticks);
  }
}
