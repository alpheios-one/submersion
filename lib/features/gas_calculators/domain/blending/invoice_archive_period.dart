import 'package:equatable/equatable.dart';

import 'package:submersion/features/gas_calculators/domain/blending/billed_fill.dart';

/// A time bucket the invoice archive section can be narrowed to.
///
/// Either a whole calendar year ([month] null) or one year+month, matching
/// whichever granularity [blenderInvoiceArchivePeriods] picks for the
/// invoices actually on file.
class BlenderInvoiceArchivePeriod extends Equatable {
  const BlenderInvoiceArchivePeriod.year(this.year) : month = null;
  const BlenderInvoiceArchivePeriod.yearMonth(this.year, this.month);

  final int year;
  final int? month;

  bool get isMonthly => month != null;

  bool matches(DateTime date) =>
      date.year == year && (month == null || date.month == month);

  @override
  List<Object?> get props => [year, month];
}

/// Buckets for [invoices], newest first.
///
/// Year buckets when the archive already spans more than one calendar year -
/// each year is then a meaningful choice on its own. Falls back to
/// year+month buckets when everything sits in a single year, where a lone
/// "2026" bucket would not narrow anything down (issue #44).
List<BlenderInvoiceArchivePeriod> blenderInvoiceArchivePeriods(
  List<ArchivedInvoice> invoices,
) {
  if (invoices.isEmpty) return const [];
  final years = {for (final invoice in invoices) invoice.date.year};
  if (years.length > 1) {
    return years.map(BlenderInvoiceArchivePeriod.year).toList()
      ..sort((a, b) => b.year.compareTo(a.year));
  }
  final months = {
    for (final invoice in invoices) (invoice.date.year, invoice.date.month),
  };
  return months
      .map((m) => BlenderInvoiceArchivePeriod.yearMonth(m.$1, m.$2))
      .toList()
    ..sort((a, b) {
      final byYear = b.year.compareTo(a.year);
      return byYear != 0 ? byYear : b.month!.compareTo(a.month!);
    });
}
