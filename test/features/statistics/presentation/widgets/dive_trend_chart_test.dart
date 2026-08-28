import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/features/statistics/domain/trend_aggregation.dart';
import 'package:submersion/features/statistics/presentation/widgets/dive_trend_chart.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

List<TrendDataPoint> series(int n) => List.generate(
  n,
  (i) => TrendDataPoint(
    date: DateTime.utc(2024, 1, 1).add(Duration(days: i * 7)),
    value: 10.0 + i,
  ),
);

Widget host(Widget child) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

LineChartData readData(WidgetTester tester) =>
    tester.widget<LineChart>(find.byType(LineChart)).data;

void main() {
  testWidgets('plots x as epoch milliseconds, not the array index', (
    tester,
  ) async {
    final points = series(6);
    await tester.pumpWidget(host(DiveTrendChart(points: points)));

    final data = readData(tester);
    final spots = data.lineBarsData.first.spots;

    expect(spots, hasLength(6));
    expect(spots.first.x, points.first.date.millisecondsSinceEpoch.toDouble());
    expect(spots.last.x, points.last.date.millisecondsSinceEpoch.toDouble());
  });

  testWidgets('the x bounds span the first and last dive', (tester) async {
    final points = series(6);
    await tester.pumpWidget(host(DiveTrendChart(points: points)));

    final data = readData(tester);

    expect(data.minX, points.first.date.millisecondsSinceEpoch.toDouble());
    expect(data.maxX, points.last.date.millisecondsSinceEpoch.toDouble());
  });

  testWidgets('draws dots with no connecting stroke in raw mode', (
    tester,
  ) async {
    await tester.pumpWidget(host(DiveTrendChart(points: series(6))));

    final bar = readData(tester).lineBarsData.first;

    expect(bar.barWidth, 0);
    expect(bar.dotData.show, isTrue);
  });

  testWidgets('a gap between dives is preserved in the x spacing', (
    tester,
  ) async {
    final points = <TrendDataPoint>[
      TrendDataPoint(date: DateTime.utc(2024, 1, 1), value: 10),
      TrendDataPoint(date: DateTime.utc(2024, 1, 2), value: 12),
      TrendDataPoint(date: DateTime.utc(2026, 1, 1), value: 40),
    ];
    await tester.pumpWidget(host(DiveTrendChart(points: points)));

    final spots = readData(tester).lineBarsData.first.spots;
    final firstGap = spots[1].x - spots[0].x;
    final secondGap = spots[2].x - spots[1].x;

    expect(secondGap, greaterThan(firstGap * 100));
  });

  testWidgets('monthly aggregation collapses to one point per month', (
    tester,
  ) async {
    final points = <TrendDataPoint>[
      TrendDataPoint(date: DateTime.utc(2024, 1, 5), value: 10),
      TrendDataPoint(date: DateTime.utc(2024, 1, 20), value: 20),
      TrendDataPoint(date: DateTime.utc(2024, 2, 5), value: 30),
    ];
    await tester.pumpWidget(
      host(
        DiveTrendChart(points: points, aggregation: TrendAggregation.monthly),
      ),
    );

    final spots = readData(tester).lineBarsData.first.spots;

    expect(spots, hasLength(2));
    expect(spots.first.y, 15); // mean of 10 and 20
  });

  testWidgets('renders the empty state rather than a chart for no dives', (
    tester,
  ) async {
    await tester.pumpWidget(host(const DiveTrendChart(points: [])));

    expect(find.byType(LineChart), findsNothing);
    expect(find.text('No trend data available'), findsOneWidget);
  });

  testWidgets('a single dive still renders a chart', (tester) async {
    await tester.pumpWidget(host(DiveTrendChart(points: series(1))));

    final data = readData(tester);

    expect(data.maxX, greaterThan(data.minX));
  });

  group('min/max band', () {
    final spread = <TrendDataPoint>[
      TrendDataPoint(date: DateTime.utc(2024, 1, 5), value: 10),
      TrendDataPoint(date: DateTime.utc(2024, 1, 20), value: 30),
      TrendDataPoint(date: DateTime.utc(2024, 2, 5), value: 40),
      TrendDataPoint(date: DateTime.utc(2024, 2, 25), value: 60),
    ];

    testWidgets('draws no band in raw mode', (tester) async {
      await tester.pumpWidget(host(DiveTrendChart(points: spread)));

      expect(readData(tester).betweenBarsData, isEmpty);
    });

    testWidgets('draws one band between the min and max series when monthly', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          DiveTrendChart(points: spread, aggregation: TrendAggregation.monthly),
        ),
      );

      final data = readData(tester);

      expect(data.betweenBarsData, hasLength(1));
      expect(data.betweenBarsData.first.fromIndex, 1);
      expect(data.betweenBarsData.first.toIndex, 2);
    });

    testWidgets('the band series carry the bucket min and max', (tester) async {
      await tester.pumpWidget(
        host(
          DiveTrendChart(points: spread, aggregation: TrendAggregation.monthly),
        ),
      );

      final bars = readData(tester).lineBarsData;

      expect(bars[1].spots.map((s) => s.y), [10, 40]);
      expect(bars[2].spots.map((s) => s.y), [30, 60]);
    });

    testWidgets('the band series are not stroked or dotted', (tester) async {
      await tester.pumpWidget(
        host(
          DiveTrendChart(points: spread, aggregation: TrendAggregation.monthly),
        ),
      );

      final bars = readData(tester).lineBarsData;

      expect(bars[1].barWidth, 0);
      expect(bars[1].dotData.show, isFalse);
      expect(bars[2].barWidth, 0);
      expect(bars[2].dotData.show, isFalse);
    });

    testWidgets('a bucket holding one dive yields a zero-height band', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          DiveTrendChart(
            points: [
              TrendDataPoint(date: DateTime.utc(2024, 1, 5), value: 10),
              TrendDataPoint(date: DateTime.utc(2024, 2, 5), value: 40),
            ],
            aggregation: TrendAggregation.monthly,
          ),
        ),
      );

      final bars = readData(tester).lineBarsData;

      expect(bars[1].spots.map((s) => s.y), bars[2].spots.map((s) => s.y));
    });

    testWidgets('the y bounds cover the band, not just the means', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          DiveTrendChart(points: spread, aggregation: TrendAggregation.monthly),
        ),
      );

      final data = readData(tester);

      expect(data.minY, lessThanOrEqualTo(10));
      expect(data.maxY, greaterThanOrEqualTo(60));
    });
  });

  group('overlays', () {
    testWidgets('draws neither overlay by default', (tester) async {
      await tester.pumpWidget(host(DiveTrendChart(points: series(20))));

      expect(readData(tester).lineBarsData, hasLength(1));
    });

    testWidgets('draws a rolling mean series when asked', (tester) async {
      await tester.pumpWidget(
        host(DiveTrendChart(points: series(20), showRollingMean: true)),
      );

      final bars = readData(tester).lineBarsData;

      expect(bars, hasLength(2));
      expect(bars.last.spots, hasLength(20));
      expect(bars.last.barWidth, greaterThan(0));
    });

    testWidgets('draws the linear fit as exactly two endpoints', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(DiveTrendChart(points: series(20), showLinearFit: true)),
      );

      final bars = readData(tester).lineBarsData;

      expect(bars, hasLength(2));
      expect(bars.last.spots, hasLength(2));
    });

    testWidgets('draws both overlays together', (tester) async {
      await tester.pumpWidget(
        host(
          DiveTrendChart(
            points: series(20),
            showRollingMean: true,
            showLinearFit: true,
          ),
        ),
      );

      expect(readData(tester).lineBarsData, hasLength(3));
    });

    testWidgets('draws no overlay below the minimum point count', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          DiveTrendChart(
            points: series(4),
            showRollingMean: true,
            showLinearFit: true,
          ),
        ),
      );

      expect(readData(tester).lineBarsData, hasLength(1));
    });

    testWidgets('the rolling mean is unchanged by the aggregation mode', (
      tester,
    ) async {
      // Both fits read the raw dives. If they read the buckets instead,
      // changing the dropdown would move the trend line and wrongly imply the
      // underlying trend had changed.
      await tester.pumpWidget(
        host(DiveTrendChart(points: series(20), showRollingMean: true)),
      );
      final raw = readData(
        tester,
      ).lineBarsData.last.spots.map((s) => s.y).toList();

      await tester.pumpWidget(
        host(
          DiveTrendChart(
            points: series(20),
            showRollingMean: true,
            aggregation: TrendAggregation.monthly,
          ),
        ),
      );
      final aggregated = readData(tester).lineBarsData
          .where((b) => b.barWidth > 0)
          .last
          .spots
          .map((s) => s.y)
          .toList();

      expect(aggregated, raw);
    });
  });
}
