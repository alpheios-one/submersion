/// Pure trend maths for the statistics charts: bucketing a per-dive series and
/// fitting curves through it. No I/O and no Flutter, so the statistical
/// behaviour is unit-testable in isolation (issue #299).
///
/// Every date here is a UTC-flagged wall clock, matching how `dive_date_time`
/// is stored and read. Bucket boundaries are built with `DateTime.utc` so the
/// machine's local offset can never shift a dive into a neighbouring bucket.
library;

/// Data point for line chart trends.
///
/// [label] is only used by the older index-axis `TrendLineChart`; per-dive
/// series leave it empty and format their axis from [date].
class TrendDataPoint {
  final DateTime date;
  final double value;
  final String label;

  TrendDataPoint({required this.date, required this.value, this.label = ''});
}

/// How a per-dive series is folded before drawing. [none] is the default: one
/// drawn point per dive.
enum TrendAggregation { none, weekly, monthly }

/// One drawn point: a single dive under [TrendAggregation.none], or the dives
/// sharing a week or month otherwise.
class TrendBucket {
  const TrendBucket({
    required this.date,
    required this.mean,
    required this.min,
    required this.max,
    required this.count,
  });

  /// Start of the bucket, or the dive's own timestamp when not aggregating.
  final DateTime date;
  final double mean;
  final double min;
  final double max;
  final int count;
}

/// Folds [points] according to [mode], always returning buckets ordered by
/// date. Input order does not matter.
List<TrendBucket> aggregate(
  List<TrendDataPoint> points,
  TrendAggregation mode,
) {
  if (points.isEmpty) return const [];

  if (mode == TrendAggregation.none) {
    final ordered = [...points]..sort((a, b) => a.date.compareTo(b.date));
    return ordered
        .map(
          (p) => TrendBucket(
            date: p.date,
            mean: p.value,
            min: p.value,
            max: p.value,
            count: 1,
          ),
        )
        .toList(growable: false);
  }

  final grouped = <DateTime, List<double>>{};
  for (final point in points) {
    final key = _bucketStart(point.date, mode);
    grouped.putIfAbsent(key, () => <double>[]).add(point.value);
  }

  final keys = grouped.keys.toList()..sort();
  return keys
      .map((key) {
        final values = grouped[key]!;
        var sum = 0.0;
        var min = values.first;
        var max = values.first;
        for (final v in values) {
          sum += v;
          if (v < min) min = v;
          if (v > max) max = v;
        }
        return TrendBucket(
          date: key,
          mean: sum / values.length,
          min: min,
          max: max,
          count: values.length,
        );
      })
      .toList(growable: false);
}

DateTime _bucketStart(DateTime date, TrendAggregation mode) {
  switch (mode) {
    case TrendAggregation.monthly:
      return DateTime.utc(date.year, date.month);
    case TrendAggregation.weekly:
      final midnight = DateTime.utc(date.year, date.month, date.day);
      // DateTime.weekday is 1 for Monday through 7 for Sunday.
      return midnight.subtract(Duration(days: midnight.weekday - 1));
    case TrendAggregation.none:
      return date;
  }
}
