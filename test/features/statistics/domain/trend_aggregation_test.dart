import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/features/statistics/domain/trend_aggregation.dart';

TrendDataPoint p(int y, int m, int d, double v) =>
    TrendDataPoint(date: DateTime.utc(y, m, d), value: v);

void main() {
  group('aggregate none', () {
    test('returns one bucket per point, mean equal to min and max', () {
      final buckets = aggregate([
        p(2024, 3, 1, 10),
        p(2024, 3, 2, 20),
      ], TrendAggregation.none);

      expect(buckets, hasLength(2));
      expect(buckets[0].date, DateTime.utc(2024, 3, 1));
      expect(buckets[0].mean, 10);
      expect(buckets[0].min, 10);
      expect(buckets[0].max, 10);
      expect(buckets[0].count, 1);
    });

    test('returns an empty list for no points', () {
      expect(aggregate(const [], TrendAggregation.none), isEmpty);
    });
  });

  group('aggregate monthly', () {
    test('collapses a month into mean, min, max and count', () {
      final buckets = aggregate([
        p(2024, 3, 1, 10),
        p(2024, 3, 20, 30),
        p(2024, 4, 2, 50),
      ], TrendAggregation.monthly);

      expect(buckets, hasLength(2));
      expect(buckets[0].date, DateTime.utc(2024, 3, 1));
      expect(buckets[0].mean, 20);
      expect(buckets[0].min, 10);
      expect(buckets[0].max, 30);
      expect(buckets[0].count, 2);
      expect(buckets[1].date, DateTime.utc(2024, 4, 1));
      expect(buckets[1].count, 1);
    });

    test('orders buckets by date regardless of input order', () {
      final buckets = aggregate([
        p(2024, 5, 1, 1),
        p(2023, 1, 1, 2),
      ], TrendAggregation.monthly);

      expect(buckets.map((b) => b.date), [
        DateTime.utc(2023, 1, 1),
        DateTime.utc(2024, 5, 1),
      ]);
    });
  });

  group('aggregate weekly', () {
    test('buckets to the Monday of the point week', () {
      // 2024-03-07 is a Thursday; its Monday is 2024-03-04.
      final buckets = aggregate([p(2024, 3, 7, 10)], TrendAggregation.weekly);

      expect(buckets.single.date, DateTime.utc(2024, 3, 4));
    });

    test('a Monday point stays on its own Monday', () {
      final buckets = aggregate([p(2024, 3, 4, 10)], TrendAggregation.weekly);

      expect(buckets.single.date, DateTime.utc(2024, 3, 4));
    });

    test(
      'a Sunday point falls into the week that started six days earlier',
      () {
        // 2024-03-10 is a Sunday.
        final buckets = aggregate([
          p(2024, 3, 10, 10),
        ], TrendAggregation.weekly);

        expect(buckets.single.date, DateTime.utc(2024, 3, 4));
      },
    );

    test('splits points across two adjacent weeks', () {
      final buckets = aggregate([
        p(2024, 3, 10, 10), // Sunday, week of Mar 4
        p(2024, 3, 11, 20), // Monday, week of Mar 11
      ], TrendAggregation.weekly);

      expect(buckets, hasLength(2));
      expect(buckets[0].date, DateTime.utc(2024, 3, 4));
      expect(buckets[1].date, DateTime.utc(2024, 3, 11));
    });
  });
}
