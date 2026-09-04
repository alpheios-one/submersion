import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/core/utils/currency.dart';
import 'package:submersion/core/utils/unit_formatter.dart';
import 'package:submersion/features/gas_calculators/domain/blending/billed_fill.dart';
import 'package:submersion/features/gas_calculators/presentation/gas_calculator_tools.dart';
import 'package:submersion/features/gas_calculators/presentation/providers/gas_blender_providers.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/l10n/l10n_extension.dart';
import 'package:submersion/shared/widgets/app_date_picker.dart';

/// Every bill the blender has marked paid: filterable by date, totalled by
/// currency, each row opening onto its own itemisation.
///
/// See issue #22 - this is deliberately the smallest useful reader over
/// [BlenderPreferences.archivedInvoices]; deeper history features (search,
/// export of the archive itself) build on top of it rather than in it.
class BlenderInvoiceArchivePage extends ConsumerWidget {
  const BlenderInvoiceArchivePage({super.key});

  Future<void> _pickRange(BuildContext context, WidgetRef ref) async {
    final settings = ref.read(settingsProvider);
    final picked = await showAppDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      initialDateRange: ref.read(blenderInvoiceArchiveFilterProvider),
      dateFormat: settings.dateFormat,
    );
    if (picked == null) return;
    ref.read(blenderInvoiceArchiveFilterProvider.notifier).state = picked;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final invoices = ref.watch(filteredBlenderArchivedInvoicesProvider);
    final allInvoices = ref.watch(blenderArchivedInvoicesProvider);
    final range = ref.watch(blenderInvoiceArchiveFilterProvider);
    final settings = ref.watch(settingsProvider);
    final units = UnitFormatter(settings);
    final fallbackCurrency = ref.watch(blenderCurrencyProvider);

    // Summed from the already-filtered rows so the total on screen matches
    // what is actually listed below it, the same reasoning as
    // ServiceHistorySection's total (#1236). A row archived before the
    // currency snapshot existed falls back to the currency configured today,
    // the best guess available for it.
    final totals = sumByCurrency<ArchivedInvoice>(
      invoices,
      amountOf: (i) => i.total,
      currencyOf: (i) => i.currencyCode ?? fallbackCurrency,
      fallbackCode: fallbackCurrency,
    ).where((e) => e.value > 0).toList();

    final hiddenByFilter = range != null && allInvoices.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.gasCalculators_blender_invoiceArchive),
        actions: [
          IconButton(
            key: const Key('blender-invoice-archive-filter'),
            icon: Badge(
              isLabelVisible: range != null,
              child: const Icon(Icons.filter_list),
            ),
            tooltip: l10n.gasCalculators_blender_invoiceArchiveFilter,
            onPressed: () => _pickRange(context, ref),
          ),
        ],
      ),
      body: Column(
        children: [
          if (range != null) _ActiveFilterBar(range: range, units: units),
          if (totals.isNotEmpty) _TotalsSummary(totals: totals),
          Expanded(
            child: invoices.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(32),
                    child: Center(
                      child: Text(
                        hiddenByFilter
                            ? l10n.gasCalculators_blender_invoiceArchiveEmptyFiltered
                            : l10n.gasCalculators_blender_invoiceArchiveEmpty,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: invoices.length,
                    itemBuilder: (context, index) => _InvoiceTile(
                      invoice: invoices[index],
                      units: units,
                      fallbackCurrency: fallbackCurrency,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _ActiveFilterBar extends ConsumerWidget {
  const _ActiveFilterBar({required this.range, required this.units});

  final DateTimeRange range;
  final UnitFormatter units;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        children: [
          Expanded(
            child: Chip(
              label: Text(
                '${units.formatDate(range.start)} - '
                '${units.formatDate(range.end)}',
              ),
              visualDensity: VisualDensity.compact,
              deleteIcon: const Icon(Icons.close, size: 16),
              onDeleted: () =>
                  ref.read(blenderInvoiceArchiveFilterProvider.notifier).state =
                      null,
            ),
          ),
        ],
      ),
    );
  }
}

class _TotalsSummary extends StatelessWidget {
  const _TotalsSummary({required this.totals});

  final List<MapEntry<String, double>> totals;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Container(
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          for (final entry in totals)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  l10n.gasCalculators_blender_billedTotal,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                Text(
                  formatMoney(entry.value, entry.key),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _InvoiceTile extends StatelessWidget {
  const _InvoiceTile({
    required this.invoice,
    required this.units,
    required this.fallbackCurrency,
  });

  final ArchivedInvoice invoice;
  final UnitFormatter units;
  final String fallbackCurrency;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final total = invoice.total;
    return ListTile(
      leading: const Icon(Icons.receipt_long_outlined),
      title: Text(
        invoice.billedTo.isEmpty
            ? l10n.gasCalculators_blender_invoiceArchiveUntitled
            : invoice.billedTo,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${units.formatDate(invoice.date)} - '
        '${l10n.gasCalculators_blender_invoiceArchiveFillCount(invoice.fills.length)}',
      ),
      trailing: Text(
        total == null
            ? l10n.gasCalculators_blender_invoiceArchiveIncomplete
            : formatMoney(total, invoice.currencyCode ?? fallbackCurrency),
        style: Theme.of(context).textTheme.titleSmall,
      ),
      onTap: () => context.push('$kBlenderInvoiceArchiveRoute/${invoice.id}'),
    );
  }
}
