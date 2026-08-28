import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/features/statistics/presentation/widgets/date_axis.dart';

void main() {
  test('bounds are the range endpoints as epoch milliseconds', () {
    final first = DateTime.utc(2024, 1, 1);
    final last = DateTime.utc(2024, 12, 31);

    final axis = DateAxis.forRange(first, last);

    expect(axis.min, first.millisecondsSinceEpoch.toDouble());
    expect(axis.max, last.millisecondsSinceEpoch.toDouble());
  });

  test('a multi-year range ticks by year', () {
    final axis = DateAxis.forRange(
      DateTime.utc(2020, 3, 5),
      DateTime.utc(2026, 8, 20),
    );

    expect(axis.granularity, DateAxisGranularity.year);
    expect(axis.ticks.every((t) => t.month == 1 && t.day == 1), isTrue);
    expect(axis.ticks.first.year, greaterThanOrEqualTo(2020));
    expect(axis.ticks.last.year, lessThanOrEqualTo(2026));
  });

  test('a range of about two years ticks by quarter', () {
    final axis = DateAxis.forRange(
      DateTime.utc(2024, 1, 1),
      DateTime.utc(2025, 12, 31),
    );

    expect(axis.granularity, DateAxisGranularity.quarter);
    expect(axis.ticks.every((t) => t.month % 3 == 1 && t.day == 1), isTrue);
  });

  test('a range of a few months ticks by month', () {
    final axis = DateAxis.forRange(
      DateTime.utc(2024, 1, 1),
      DateTime.utc(2024, 5, 31),
    );

    expect(axis.granularity, DateAxisGranularity.month);
    expect(axis.ticks.every((t) => t.day == 1), isTrue);
  });

  test('a range of a few weeks ticks by day', () {
    final axis = DateAxis.forRange(
      DateTime.utc(2024, 1, 1),
      DateTime.utc(2024, 1, 20),
    );

    expect(axis.granularity, DateAxisGranularity.day);
    expect(axis.ticks, isNotEmpty);
  });

  test('every tick lies inside the bounds', () {
    final axis = DateAxis.forRange(
      DateTime.utc(2020, 3, 5),
      DateTime.utc(2026, 8, 20),
    );

    for (final tick in axis.ticks) {
      final ms = tick.millisecondsSinceEpoch.toDouble();
      expect(ms, greaterThanOrEqualTo(axis.min));
      expect(ms, lessThanOrEqualTo(axis.max));
    }
  });

  test('a single-instant range still yields a drawable axis', () {
    final only = DateTime.utc(2024, 6, 1);

    final axis = DateAxis.forRange(only, only);

    expect(axis.max, greaterThan(axis.min));
    expect(axis.ticks, isNotEmpty);
  });

  test('ticks are strictly increasing', () {
    final axis = DateAxis.forRange(
      DateTime.utc(2021, 6, 1),
      DateTime.utc(2026, 6, 1),
    );

    for (var i = 1; i < axis.ticks.length; i++) {
      expect(axis.ticks[i].isAfter(axis.ticks[i - 1]), isTrue);
    }
  });

  group('showsLabelAt', () {
    final axis = DateAxis.forRange(
      DateTime.utc(2024, 1, 1),
      DateTime.utc(2024, 9, 15),
    );

    test('labels both bounds', () {
      expect(axis.showsLabelAt(axis.min), isTrue);
      expect(axis.showsLabelAt(axis.max), isTrue);
    });

    test('refuses anything outside the bounds', () {
      expect(axis.showsLabelAt(axis.min - 1), isFalse);
      expect(axis.showsLabelAt(axis.max + 1), isFalse);
    });

    test('suppresses a label that would crowd the upper bound', () {
      // fl_chart draws the max label regardless, so a derived label a sliver
      // before it renders as one run of jammed text.
      expect(axis.showsLabelAt(axis.max - axis.labelInterval * 0.1), isFalse);
    });

    test('suppresses a label that would crowd the lower bound', () {
      expect(axis.showsLabelAt(axis.min + axis.labelInterval * 0.1), isFalse);
    });

    test('keeps a label a full interval clear of the bounds', () {
      expect(axis.showsLabelAt(axis.min + axis.labelInterval), isTrue);
      expect(axis.showsLabelAt(axis.max - axis.labelInterval), isTrue);
    });
  });
}
