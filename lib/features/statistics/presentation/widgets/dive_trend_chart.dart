import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:submersion/features/statistics/domain/trend_aggregation.dart';
import 'package:submersion/features/statistics/presentation/widgets/chart_axis.dart';
import 'package:submersion/features/statistics/presentation/widgets/date_axis.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// A per-dive trend chart on a real date axis.
///
/// Distinct from `TrendLineChart`, which plots `FlSpot(index, value)` and so
/// draws a three-month gap and a three-week gap identically. That is fine for
/// a dense monthly series; it is not fine for individual dives, which cluster
/// hard around trips (issue #299).
///
/// Layers, all sharing one set of axes:
///  - the data, as dots when raw or a mean line when aggregated
///  - a rolling mean, optional
///  - a linear fit, optional
///
/// fl_chart's ScatterChart is deliberately not used: it cannot carry the
/// overlay line series alongside the points.
class DiveTrendChart extends StatelessWidget {
  const DiveTrendChart({
    super.key,
    required this.points,
    this.aggregation = TrendAggregation.none,
    this.showRollingMean = false,
    this.showLinearFit = false,
    this.pointColor,
    this.rollingColor,
    this.rateColor,
    this.yAxisLabel,
    this.height = 200,
    this.valueFormatter,
    this.yAxisFormatter,
  });

  /// Raw per-dive points, in any order. Never pre-aggregated by the caller.
  final List<TrendDataPoint> points;

  final TrendAggregation aggregation;
  final bool showRollingMean;
  final bool showLinearFit;
  final Color? pointColor;
  final Color? rollingColor;
  final Color? rateColor;
  final String? yAxisLabel;
  final double height;
  final String Function(double)? valueFormatter;
  final String Function(double)? yAxisFormatter;

  static double _x(DateTime date) => date.millisecondsSinceEpoch.toDouble();

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) {
      return _EmptyChart(height: height);
    }

    final theme = Theme.of(context);
    final color = pointColor ?? theme.colorScheme.primary;

    final buckets = aggregate(points, aggregation);
    final dateAxis = DateAxis.forRange(buckets.first.date, buckets.last.date);
    final yAxis = ChartAxis.forTrend(buckets.expand((b) => [b.min, b.max]));

    final isRaw = aggregation == TrendAggregation.none;

    return Semantics(
      label: yAxisLabel != null
          ? context.l10n.statistics_chart_trendSemanticLabelWithAxis(
              points.length,
              yAxisLabel!,
            )
          : context.l10n.statistics_chart_trendSemanticLabel(points.length),
      child: SizedBox(
        height: height,
        child: LineChart(
          LineChartData(
            minX: dateAxis.min,
            maxX: dateAxis.max,
            minY: yAxis.min,
            maxY: yAxis.max,
            lineTouchData: _touchData(context),
            titlesData: _titles(context, dateAxis, yAxis),
            borderData: FlBorderData(show: false),
            gridData: FlGridData(
              show: true,
              drawVerticalLine: false,
              horizontalInterval: yAxis.interval,
              getDrawingHorizontalLine: (value) => FlLine(
                color: theme.colorScheme.outlineVariant,
                strokeWidth: 1,
              ),
            ),
            lineBarsData: _bars(context, buckets, color, isRaw),
            betweenBarsData: _bands(context, isRaw),
          ),
        ),
      ),
    );
  }

  /// Index 0 is always the data series. When aggregating, indices 1 and 2 are
  /// the invisible bucket min and max that [_bands] fills between.
  List<LineChartBarData> _bars(
    BuildContext context,
    List<TrendBucket> buckets,
    Color color,
    bool isRaw,
  ) {
    final bars = <LineChartBarData>[
      LineChartBarData(
        spots: buckets
            .map((b) => FlSpot(_x(b.date), b.mean))
            .toList(growable: false),
        isCurved: false,
        color: color,
        // Raw mode draws dots only: a stroke between two dives eight months
        // apart would assert something happened in between.
        barWidth: isRaw ? 0 : 2,
        isStrokeCapRound: true,
        dotData: FlDotData(
          show: isRaw,
          getDotPainter: (spot, percent, barData, index) => FlDotCirclePainter(
            radius: 2.2,
            color: color.withValues(alpha: 0.7),
            strokeWidth: 0,
          ),
        ),
      ),
    ];

    if (!isRaw) {
      for (final selector in <double Function(TrendBucket)>[
        (b) => b.min,
        (b) => b.max,
      ]) {
        bars.add(
          LineChartBarData(
            spots: buckets
                .map((b) => FlSpot(_x(b.date), selector(b)))
                .toList(growable: false),
            isCurved: false,
            barWidth: 0,
            color: Colors.transparent,
            dotData: const FlDotData(show: false),
          ),
        );
      }
    }

    return bars;
  }

  /// Fills between the min and max series so an aggregated chart still shows
  /// the spread. Smoothing must not put back the hiding this issue is about.
  List<BetweenBarsData> _bands(BuildContext context, bool isRaw) {
    if (isRaw) return const [];
    final color = pointColor ?? Theme.of(context).colorScheme.primary;
    return [
      BetweenBarsData(
        fromIndex: 1,
        toIndex: 2,
        color: color.withValues(alpha: 0.15),
      ),
    ];
  }

  LineTouchData _touchData(BuildContext context) {
    return LineTouchData(
      touchTooltipData: LineTouchTooltipData(
        getTooltipItems: (touchedSpots) {
          return touchedSpots.map((spot) {
            final date = DateTime.fromMillisecondsSinceEpoch(
              spot.x.toInt(),
              isUtc: true,
            );
            final value =
                valueFormatter?.call(spot.y) ?? spot.y.toStringAsFixed(1);
            return LineTooltipItem(
              '${DateFormat.yMMMd().format(date)}\n$value',
              TextStyle(
                color: Theme.of(context).colorScheme.onPrimary,
                fontWeight: FontWeight.bold,
              ),
            );
          }).toList();
        },
      ),
    );
  }

  FlTitlesData _titles(
    BuildContext context,
    DateAxis dateAxis,
    ChartAxis yAxis,
  ) {
    final tickMs = dateAxis.ticks.map((t) => t.millisecondsSinceEpoch).toSet();

    return FlTitlesData(
      show: true,
      bottomTitles: AxisTitles(
        sideTitles: SideTitles(
          showTitles: true,
          reservedSize: 30,
          getTitlesWidget: (value, meta) {
            if (!tickMs.contains(value.toInt())) return const Text('');
            final date = DateTime.fromMillisecondsSinceEpoch(
              value.toInt(),
              isUtc: true,
            );
            return Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _formatTick(date, dateAxis.granularity),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            );
          },
        ),
      ),
      leftTitles: AxisTitles(
        axisNameWidget: yAxisLabel != null
            ? Text(yAxisLabel!, style: Theme.of(context).textTheme.bodySmall)
            : null,
        axisNameSize: yAxisLabel != null ? 20 : 0,
        sideTitles: SideTitles(
          showTitles: true,
          reservedSize: 50,
          interval: yAxis.interval,
          getTitlesWidget: (value, meta) {
            final formatter = yAxisFormatter ?? valueFormatter;
            return Text(
              formatter?.call(value) ?? value.toStringAsFixed(0),
              style: Theme.of(context).textTheme.bodySmall,
            );
          },
        ),
      ),
      topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
    );
  }

  String _formatTick(DateTime date, DateAxisGranularity granularity) {
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
}

/// Same empty state as `TrendLineChart`, so a chart with no dives reads the
/// same wherever it appears.
class _EmptyChart extends StatelessWidget {
  const _EmptyChart({required this.height});

  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.show_chart,
              size: 48,
              color: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 8),
            Text(
              context.l10n.statistics_chart_noTrendData,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
