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

import 'package:intl/intl.dart';

enum DateAxisGranularity { day, month, quarter, year }

class DateAxis {
  const DateAxis({
    required this.min,
    required this.max,
    required this.ticks,
    required this.granularity,
    required this.labelInterval,
  });

  /// Lower bound, as `millisecondsSinceEpoch`, for fl_chart's `minX`.
  final double min;

  /// Upper bound, as `millisecondsSinceEpoch`, for fl_chart's `maxX`.
  final double max;

  /// Tick positions, strictly increasing and always inside the bounds.
  final List<DateTime> ticks;

  final DateAxisGranularity granularity;

  /// Spacing, in milliseconds, to hand fl_chart as `SideTitles.interval`.
  ///
  /// fl_chart calls `getTitlesWidget` only at values it derives from this
  /// interval, so a label drawn by matching a nominated tick timestamp exactly
  /// would essentially never render. Deriving a uniform step from the tick
  /// count and formatting whatever value arrives is what actually puts labels
  /// on the axis (issue #299 smoke check).
  final double labelInterval;

  /// Whether a label should be drawn at [value].
  ///
  /// fl_chart draws a label at [max] on top of the ones it derives from
  /// [labelInterval], so the last derived label can land almost on top of it
  /// and the two render as one run of jammed text ("AprMay"). Suppress any
  /// derived label that crowds a bound; the bound's own label stands.
  bool showsLabelAt(double value) {
    if (value < min || value > max) return false;
    if (value == min || value == max) return true;
    final crowding = labelInterval * 0.6;
    return (max - value) >= crowding && (value - min) >= crowding;
  }

  /// The text to draw at [value], or null when nothing should be drawn.
  ///
  /// Beyond the bound-crowding rule, this drops a label that repeats the one
  /// in the preceding slot. The step is uniform but months and years are not,
  /// so it drifts off real calendar boundaries and two adjacent slots can land
  /// in the same month ("Sep Sep").
  ///
  /// [step] must be the spacing fl_chart actually applied
  /// (`TitleMeta.appliedInterval`), not the [labelInterval] we requested.
  /// fl_chart is free to use a different one, and comparing against a value it
  /// never drew silently defeats the check.
  String? labelFor(double value, {double? step}) {
    if (!showsLabelAt(value)) return null;

    final date = _dateOf(value);
    final text = _format(date);

    // The previously drawn label is one step back, or the lower bound when
    // that step would fall outside the axis. fl_chart does not anchor its
    // step sequence at min, so the first derived label can sit less than a
    // step from the bound: without the clamp that pair goes uncompared, which
    // is exactly how "Sep Sep" survived.
    var previous = value - (step ?? labelInterval);
    if (previous < min) previous = min;
    final hasPrevious = previous < value && showsLabelAt(previous);

    if (hasPrevious) {
      final previousDate = _dateOf(previous);
      if (_format(previousDate) == text) return null;
      // A bare "Oct" never says which October, so the year is spelled out
      // wherever it changes. Repeating it on every tick would just crowd the
      // axis, which is what makes labels collide.
      if (previousDate.year == date.year) return text;
    }
    return _formatWithYear(date);
  }

  static DateTime _dateOf(double ms) =>
      DateTime.fromMillisecondsSinceEpoch(ms.toInt(), isUtc: true);

  /// The label without a year. Also the key the duplicate check compares on,
  /// so "Sep 2025" and "Sep" still count as the same month.
  String _format(DateTime date) {
    switch (granularity) {
      case DateAxisGranularity.year:
        return DateFormat.y().format(date);
      case DateAxisGranularity.quarter:
      case DateAxisGranularity.month:
        return DateFormat.MMM().format(date);
      case DateAxisGranularity.day:
        return DateFormat.Md().format(date);
    }
  }

  String _formatWithYear(DateTime date) {
    switch (granularity) {
      case DateAxisGranularity.year:
        // Already a year.
        return DateFormat.y().format(date);
      case DateAxisGranularity.quarter:
      case DateAxisGranularity.month:
        return DateFormat.yMMM().format(date);
      case DateAxisGranularity.day:
        return DateFormat.yMd().format(date);
    }
  }

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

    final ticks = _ticksFor(start, end, granularity);
    final minMs = start.millisecondsSinceEpoch.toDouble();
    final maxMs = end.millisecondsSinceEpoch.toDouble();
    final steps = ticks.length > 1 ? ticks.length - 1 : 1;

    return DateAxis(
      min: minMs,
      max: maxMs,
      ticks: ticks,
      granularity: granularity,
      labelInterval: (maxMs - minMs) / steps,
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
