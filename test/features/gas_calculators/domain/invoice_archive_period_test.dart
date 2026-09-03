import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/features/gas_calculators/domain/blending/billed_fill.dart';
import 'package:submersion/features/gas_calculators/domain/blending/invoice_archive_period.dart';

ArchivedInvoice _invoice(DateTime date) => ArchivedInvoice(
  id: date.toIso8601String(),
  date: date,
  billedTo: '',
  fills: const [],
  total: 10,
);

void main() {
  group('blenderInvoiceArchivePeriods', () {
    test('is empty for an empty archive', () {
      expect(blenderInvoiceArchivePeriods(const []), isEmpty);
    });

    test(
      'buckets by year, newest first, when invoices span more than one year',
      () {
        final periods = blenderInvoiceArchivePeriods([
          _invoice(DateTime(2025, 12, 1)),
          _invoice(DateTime(2026, 4, 3)),
          _invoice(DateTime(2025, 2, 1)),
        ]);

        expect(periods, [
          const BlenderInvoiceArchivePeriod.year(2026),
          const BlenderInvoiceArchivePeriod.year(2025),
        ]);
        expect(periods.every((p) => !p.isMonthly), isTrue);
      },
    );

    test(
      'buckets by year+month, newest first, when everything is one year',
      () {
        final periods = blenderInvoiceArchivePeriods([
          _invoice(DateTime(2026, 1, 5)),
          _invoice(DateTime(2026, 3, 20)),
          _invoice(DateTime(2026, 3, 2)),
        ]);

        expect(periods, [
          const BlenderInvoiceArchivePeriod.yearMonth(2026, 3),
          const BlenderInvoiceArchivePeriod.yearMonth(2026, 1),
        ]);
        expect(periods.every((p) => p.isMonthly), isTrue);
      },
    );

    test('a single invoice still yields one year+month bucket', () {
      final periods = blenderInvoiceArchivePeriods([
        _invoice(DateTime(2026, 6, 15)),
      ]);

      expect(periods, [const BlenderInvoiceArchivePeriod.yearMonth(2026, 6)]);
    });
  });

  group('BlenderInvoiceArchivePeriod.matches', () {
    test('a year bucket matches any month within that year', () {
      const period = BlenderInvoiceArchivePeriod.year(2026);
      expect(period.matches(DateTime(2026, 1, 1)), isTrue);
      expect(period.matches(DateTime(2026, 12, 31)), isTrue);
      expect(period.matches(DateTime(2025, 12, 31)), isFalse);
    });

    test('a year+month bucket matches only that month', () {
      const period = BlenderInvoiceArchivePeriod.yearMonth(2026, 4);
      expect(period.matches(DateTime(2026, 4, 1)), isTrue);
      expect(period.matches(DateTime(2026, 4, 30)), isTrue);
      expect(period.matches(DateTime(2026, 5, 1)), isFalse);
      expect(period.matches(DateTime(2025, 4, 1)), isFalse);
    });
  });
}
