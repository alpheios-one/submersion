import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/core/utils/unit_formatter.dart';
import 'package:submersion/features/gas_calculators/domain/blending/invoice_archive_period.dart';
import 'package:submersion/features/gas_calculators/presentation/providers/gas_blender_providers.dart';
import 'package:submersion/features/gas_calculators/presentation/widgets/blender/blender_archived_invoice_tile.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// A collapsible read of [blenderArchivedInvoicesProvider], shown right below
/// the running bill so a fill station can glance at a past receipt without
/// leaving the calculator for the full archive page (issue #44).
///
/// That page - `BlenderInvoiceArchivePage`, and its history-icon entry point
/// in `BlenderInvoiceCard._dateHeader` - stays untouched: this section has no
/// date-range picker or currency totals of its own, only the year/month
/// bucket picker below. Hidden entirely once nothing has been paid yet, same
/// as the card sections above it that have nothing to show.
class BlenderInvoiceArchiveSection extends ConsumerStatefulWidget {
  const BlenderInvoiceArchiveSection({super.key});

  @override
  ConsumerState<BlenderInvoiceArchiveSection> createState() =>
      _BlenderInvoiceArchiveSectionState();
}

class _BlenderInvoiceArchiveSectionState
    extends ConsumerState<BlenderInvoiceArchiveSection> {
  /// Local rather than a provider, matching ServiceHistorySection: a view of
  /// this card, not state that needs to outlive it.
  bool _expanded = false;
  BlenderInvoiceArchivePeriod? _selectedPeriod;

  @override
  Widget build(BuildContext context) {
    final invoices = ref.watch(blenderArchivedInvoicesProvider);
    if (invoices.isEmpty) return const SizedBox.shrink();

    final periods = blenderInvoiceArchivePeriods(invoices);
    // The newest bucket wins whenever the current pick no longer applies -
    // the first time this opens, or the granularity just changed underneath
    // it (a second year appearing switches year+month buckets to year ones).
    final selected = periods.contains(_selectedPeriod)
        ? _selectedPeriod!
        : periods.first;

    final settings = ref.watch(settingsProvider);
    final units = UnitFormatter(settings);
    final fallbackCurrency = ref.watch(blenderCurrencyProvider);
    final visible =
        invoices.where((invoice) => selected.matches(invoice.date)).toList()
          ..sort((a, b) => b.date.compareTo(a.date));

    final theme = Theme.of(context);
    final l10n = context.l10n;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              key: const Key('blender-invoice-archive-section-toggle'),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Row(
                children: [
                  Icon(
                    Icons.receipt_long_outlined,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.gasCalculators_blender_invoiceArchive,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  Icon(_expanded ? Icons.expand_less : Icons.expand_more),
                ],
              ),
            ),
            if (_expanded) ...[
              const Divider(),
              _PeriodDropdown(
                periods: periods,
                selected: selected,
                onChanged: (period) => setState(() => _selectedPeriod = period),
              ),
              const SizedBox(height: 4),
              for (final invoice in visible)
                BlenderArchivedInvoiceTile(
                  key: ValueKey(
                    'blender-invoice-archive-section-${invoice.id}',
                  ),
                  invoice: invoice,
                  units: units,
                  fallbackCurrency: fallbackCurrency,
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The year or year+month bucket picker. Bordered container with the
/// underline suppressed, matching ServiceHistorySection's filter dropdowns.
class _PeriodDropdown extends StatelessWidget {
  const _PeriodDropdown({
    required this.periods,
    required this.selected,
    required this.onChanged,
  });

  final List<BlenderInvoiceArchivePeriod> periods;
  final BlenderInvoiceArchivePeriod selected;
  final ValueChanged<BlenderInvoiceArchivePeriod> onChanged;

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context).toString();
    return Container(
      key: const Key('blender-invoice-archive-section-period'),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outline),
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButton<BlenderInvoiceArchivePeriod>(
        value: selected,
        underline: const SizedBox(),
        isDense: true,
        items: [
          for (final period in periods)
            DropdownMenuItem(
              value: period,
              child: Text(_label(period, locale)),
            ),
        ],
        onChanged: (period) {
          if (period != null) onChanged(period);
        },
      ),
    );
  }

  /// A bare year for a year bucket, and the locale's own month+year order
  /// (e.g. "April 2026" in German, but not everywhere) for a month bucket -
  /// no hand-maintained month-name translation table needed, matching how
  /// `MediaLibraryGroupedList` labels its month headers.
  String _label(BlenderInvoiceArchivePeriod period, String locale) =>
      period.isMonthly
      ? DateFormat.yMMMM(locale).format(DateTime(period.year, period.month!))
      : DateFormat.y(locale).format(DateTime(period.year));
}
