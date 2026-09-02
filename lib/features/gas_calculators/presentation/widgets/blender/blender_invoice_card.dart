import 'package:flutter/material.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/core/services/export/export_service.dart';
import 'package:submersion/core/utils/currency.dart';
import 'package:submersion/core/utils/number_input.dart';
import 'package:submersion/core/utils/unit_formatter.dart';
import 'package:submersion/features/divers/presentation/providers/diver_providers.dart';
import 'package:submersion/features/gas_calculators/domain/blending/billed_fill.dart';
import 'package:submersion/features/gas_calculators/presentation/providers/gas_blender_providers.dart';
import 'package:submersion/features/gas_calculators/presentation/widgets/blender/blender_formatting.dart';
import 'package:submersion/features/gas_calculators/presentation/widgets/blender/blender_invoice_export_sheet.dart';
import 'package:submersion/features/gas_calculators/presentation/widgets/blender/blender_section_title.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/l10n/l10n_extension.dart';
import 'package:submersion/shared/widgets/app_date_picker.dart';

/// The running bill for a blending session.
///
/// A fill station rarely does one cylinder. Without this the blender has to
/// write each finished fill down on paper before starting the next, because
/// the next blend replaces the one on screen (issue #1100).
class BlenderInvoiceCard extends ConsumerStatefulWidget {
  const BlenderInvoiceCard({super.key});

  @override
  ConsumerState<BlenderInvoiceCard> createState() => _BlenderInvoiceCardState();
}

class _BlenderInvoiceCardState extends ConsumerState<BlenderInvoiceCard> {
  late final TextEditingController _billedTo;

  /// The logbook name is a starting point, offered once. Re-seeding on every
  /// rebuild would fight the diver as they typed a customer's name.
  bool _seededBilledTo = false;

  /// Wraps the whole card for the "Export as Image" option, so it captures
  /// exactly what the diver is already looking at.
  final _exportBoundaryKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _billedTo = TextEditingController(text: ref.read(blenderBilledToProvider));
  }

  @override
  void dispose() {
    _billedTo.dispose();
    super.dispose();
  }

  /// Fill in [name] the first time one is available and the field is still
  /// untouched. Scheduled off the build because it writes provider state.
  void _seedBilledTo(String name) {
    if (name.isEmpty || _seededBilledTo) return;
    if (ref.read(blenderBilledToProvider).isNotEmpty) {
      _seededBilledTo = true;
      return;
    }
    _seededBilledTo = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (ref.read(blenderBilledToProvider).isNotEmpty) return;
      ref.read(blenderBilledToProvider.notifier).state = name;
      _billedTo.text = name;
    });
  }

  @override
  Widget build(BuildContext context) {
    final fills = ref.watch(blenderBilledFillsProvider);
    final currency = ref.watch(blenderCurrencyProvider);
    final settings = ref.watch(settingsProvider);
    final units = UnitFormatter(settings);
    final decimals = pressureDecimalsFor(settings.pressureUnit);
    final total = totalOf(fills);
    final billedDate = ref.watch(blenderBilledDateProvider);
    final theme = Theme.of(context);

    // Seed the name from the logbook, once, and only when the diver has not
    // typed one. A fill station fills other people's cylinders, so this is a
    // starting point rather than a fixed label.
    //
    // Watched, not listened to: currentDiverProvider is resolved long before
    // anyone opens the calculators tab, and ref.listen fires only on a later
    // change, so the listener never ran in the real app (PR #1215 review).
    final diver = ref.watch(currentDiverProvider).valueOrNull;
    _seedBilledTo(diver?.name.trim() ?? '');

    return RepaintBoundary(
      key: _exportBoundaryKey,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _dateHeader(context, billedDate, settings),
              _tariffSummary(context, settings, currency),
              TextField(
                controller: _billedTo,
                decoration: InputDecoration(
                  labelText: context.l10n.gasCalculators_blender_billedTo,
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (v) =>
                    ref.read(blenderBilledToProvider.notifier).state = v,
                onEditingComplete: () => saveBlenderPreferences(ref),
                onSubmitted: (_) => saveBlenderPreferences(ref),
              ),
              const SizedBox(height: 16),
              if (fills.isEmpty)
                Text(
                  context.l10n.gasCalculators_blender_billedNone,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                )
              else
                for (final f in fills)
                  _fillLine(context, f, currency, units, decimals),
              const SizedBox(height: 8),
              TextButton.icon(
                key: const Key('blender-add-manual-line'),
                onPressed: () => _editLine(null),
                icon: const Icon(Icons.add, size: 18),
                label: Text(context.l10n.gasCalculators_blender_addManualLine),
              ),
              if (fills.isNotEmpty) ...[
                const Divider(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      context.l10n.gasCalculators_blender_billedTotal,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      formatMoney(total.amount, currency),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                if (!total.complete)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      context.l10n.gasCalculators_blender_billedIncomplete,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                // A Wrap so the two actions drop to separate lines on the
                // narrowest phone rather than overflowing.
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.end,
                  children: [
                    OutlinedButton.icon(
                      key: const Key('blender-export'),
                      onPressed: () => _openExportSheet(
                        context,
                        fills,
                        currency,
                        units,
                        decimals,
                        billedDate,
                        total,
                      ),
                      icon: const Icon(Icons.ios_share, size: 18),
                      label: Text(context.l10n.gasCalculators_blender_export),
                    ),
                    FilledButton.icon(
                      key: const Key('blender-pay'),
                      onPressed: _confirmPay,
                      icon: const Icon(Icons.check_circle_outline, size: 18),
                      label: Text(context.l10n.gasCalculators_blender_pay),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _dateHeader(
    BuildContext context,
    DateTime date,
    AppSettings settings,
  ) {
    final units = UnitFormatter(settings);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Expanded(
            child: BlenderSectionTitle(
              context.l10n.gasCalculators_blender_billedDate(
                units.formatDate(date),
              ),
            ),
          ),
          IconButton(
            key: const Key('blender-billed-date-edit'),
            icon: const Icon(Icons.edit_calendar_outlined, size: 20),
            visualDensity: VisualDensity.compact,
            tooltip: context.l10n.gasCalculators_blender_billedDateEdit,
            onPressed: () => _pickDate(context, date, settings),
          ),
        ],
      ),
    );
  }

  Future<void> _pickDate(
    BuildContext context,
    DateTime current,
    AppSettings settings,
  ) async {
    final picked = await showAppDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      dateFormat: settings.dateFormat,
    );
    if (picked == null) return;
    ref.read(blenderBilledDateProvider.notifier).state = picked;
    saveBlenderPreferences(ref);
  }

  /// The gas tariff, so it can be checked at a glance without switching to
  /// the "Cost" card. Zipped by bank index against the gas *currently*
  /// configured for that bank, matching how the price fields there are
  /// labelled - not by grouping historical invoice lines, which may have
  /// been filled from a bank since reconfigured to a different gas
  /// (PR #1215 review).
  Widget _tariffSummary(
    BuildContext context,
    AppSettings settings,
    String currency,
  ) {
    final gases = [
      ref.watch(blenderFillGas1Provider),
      ref.watch(blenderFillGas2Provider),
      ref.watch(blenderFillGas3Provider),
    ];
    final prices = ref.watch(blenderGasPricesProvider);
    final units = UnitFormatter(settings);
    final parts = <String>[];
    for (var i = 0; i < gases.length; i++) {
      final price = i < prices.length ? prices[i] : null;
      if (price == null) continue;
      final display = blenderDisplayPrice(price, settings);
      parts.add(
        '${formatPreciseGasName(context, gases[i])} '
        '${formatMoney(display, currency)}/100${units.volumeSymbol}',
      );
    }
    if (parts.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        '${context.l10n.gasCalculators_blender_tariff}: ${parts.join('  ·  ')}',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  void _openExportSheet(
    BuildContext context,
    List<BilledFill> fills,
    String currency,
    UnitFormatter units,
    int decimals,
    DateTime billedDate,
    BilledTotal total,
  ) {
    final settings = ref.read(settingsProvider);
    final gases = [
      ref.read(blenderFillGas1Provider),
      ref.read(blenderFillGas2Provider),
      ref.read(blenderFillGas3Provider),
    ];
    final prices = ref.read(blenderGasPricesProvider);
    final tariffParts = <String>[];
    for (var i = 0; i < gases.length; i++) {
      final price = i < prices.length ? prices[i] : null;
      if (price == null) continue;
      final display = blenderDisplayPrice(price, settings);
      tariffParts.add(
        '${formatPreciseGasName(context, gases[i])} '
        '${formatMoney(display, currency)}/100${units.volumeSymbol}',
      );
    }

    final data = BlenderInvoiceExportData(
      date: context.l10n.gasCalculators_blender_billedDate(
        units.formatDate(billedDate),
      ),
      billedTo: ref.read(blenderBilledToProvider),
      tariff: tariffParts.join('  ·  '),
      fills: [
        for (final fill in fills)
          BlenderInvoiceExportFill(
            label: fill.label,
            total: fill.total == null ? '' : formatMoney(fill.total!, currency),
            lines: [
              for (final line in fill.lines)
                BlenderInvoiceExportLine(
                  gas: line.gas,
                  volume: line.freeGasLiters != null
                      ? units.formatVolume(line.freeGasLiters)
                      : units.formatPressure(line.addedBar, decimals: decimals),
                  cost: line.cost == null
                      ? ''
                      : formatMoney(line.cost!, currency),
                ),
            ],
          ),
      ],
      total: total.complete ? formatMoney(total.amount, currency) : '',
      incomplete: !total.complete,
    );

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => BlenderInvoiceExportSheet(
        data: data,
        imageBoundaryKey: _exportBoundaryKey,
      ),
    );
  }

  Widget _fillLine(
    BuildContext context,
    BilledFill fill,
    String currency,
    UnitFormatter units,
    int decimals,
  ) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                flex: 2,
                child: Text(
                  fill.label,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Flexible(
                child: Text(
                  fill.total == null ? '' : formatMoney(fill.total!, currency),
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.end,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // Compact so a label, an amount and two actions still fit the
              // narrowest phone the app supports.
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 18),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                tooltip: context.l10n.gasCalculators_blender_editLine(
                  fill.label,
                ),
                onPressed: () => _editLine(fill),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                tooltip: context.l10n.gasCalculators_blender_deleteLine(
                  fill.label,
                ),
                onPressed: () => _delete(fill),
              ),
            ],
          ),
          // The itemisation is what makes the total checkable at the counter,
          // so it stays visible rather than hiding behind a disclosure.
          for (final line in fill.lines)
            Padding(
              padding: const EdgeInsets.only(left: 16, top: 2),
              child: Row(
                children: [
                  Expanded(
                    flex: 4,
                    child: Text(line.gas, style: theme.textTheme.bodySmall),
                  ),
                  Expanded(
                    flex: 4,
                    child: Text(
                      // Volume when this line has one (every fill saved
                      // since #1335); pressure-only rows saved before that
                      // fall back, since their volume was never kept.
                      line.freeGasLiters != null
                          ? units.formatVolume(line.freeGasLiters)
                          : units.formatPressure(
                              line.addedBar,
                              decimals: decimals,
                            ),
                      style: theme.textTheme.bodySmall,
                      textAlign: TextAlign.end,
                    ),
                  ),
                  Expanded(
                    flex: 4,
                    child: Text(
                      line.cost == null
                          ? ''
                          : formatMoney(line.cost!, currency),
                      style: theme.textTheme.bodySmall,
                      textAlign: TextAlign.end,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  void _delete(BilledFill fill) {
    ref.read(blenderBilledFillsProvider.notifier).state = [
      ...ref.read(blenderBilledFillsProvider).where((f) => f.id != fill.id),
    ];
    saveBlenderPreferences(ref);
  }

  /// Edit an existing line, or add a manual one when [fill] is null.
  ///
  /// The amount stays editable on computed fills too: rounding and the
  /// occasional discount happen at a real counter, and re-blending the
  /// cylinder to change what it costs would be absurd.
  Future<void> _editLine(BilledFill? fill) async {
    final edited = await showDialog<_LineEdit>(
      context: context,
      builder: (context) => _LineEditDialog(fill: fill),
    );
    if (edited == null) return;

    final fills = ref.read(blenderBilledFillsProvider);
    if (fill == null) {
      ref.read(blenderBilledFillsProvider.notifier).state = appendCapped(
        fills,
        BilledFill(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          label: edited.label,
          lines: const [],
          total: edited.amount,
        ),
      );
    } else {
      ref.read(blenderBilledFillsProvider.notifier).state = [
        for (final f in fills)
          if (f.id == fill.id)
            f.copyWith(
              label: edited.label,
              total: edited.amount,
              clearTotal: edited.amount == null,
            )
          else
            f,
      ];
    }
    saveBlenderPreferences(ref);
  }

  /// Archives the running bill and starts a fresh one.
  ///
  /// Replaces the old "Clear" action rather than sitting beside it: a bill
  /// that is only cleared, never archived, is the exact history gap issue
  /// #22 (a full invoice archive view) would otherwise have to backfill from
  /// nothing. The confirmation dialog is kept, since paying is just as
  /// destructive to the running bill as clearing was.
  Future<void> _confirmPay() async {
    final fills = ref.read(blenderBilledFillsProvider);
    final count = fills.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.gasCalculators_blender_payTitle),
        content: Text(context.l10n.gasCalculators_blender_payBody(count)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n.common_action_close),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.l10n.gasCalculators_blender_pay),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final total = totalOf(fills);
    final archived = ArchivedInvoice(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      date: ref.read(blenderBilledDateProvider),
      billedTo: ref.read(blenderBilledToProvider),
      fills: fills,
      total: total.complete ? total.amount : null,
    );
    ref
        .read(blenderArchivedInvoicesProvider.notifier)
        .state = appendArchivedCapped(
      ref.read(blenderArchivedInvoicesProvider),
      archived,
    );
    ref.read(blenderBilledFillsProvider.notifier).state = const [];
    ref.read(blenderBilledDateProvider.notifier).state = DateTime.now();
    saveBlenderPreferences(ref);
  }
}

/// What the edit dialog hands back.
class _LineEdit {
  const _LineEdit({required this.label, required this.amount});
  final String label;
  final double? amount;
}

/// Owns its own controllers, and disposes them in its own State.
///
/// Creating them in the caller and disposing on the dialog future looks
/// equivalent and is not: the future completes when the route is popped, while
/// the exit transition keeps rebuilding these fields for several more frames
/// against a controller that is already gone.
class _LineEditDialog extends StatefulWidget {
  const _LineEditDialog({required this.fill});

  final BilledFill? fill;

  @override
  State<_LineEditDialog> createState() => _LineEditDialogState();
}

class _LineEditDialogState extends State<_LineEditDialog> {
  late final TextEditingController _label;
  late final TextEditingController _amount;

  @override
  void initState() {
    super.initState();
    final fill = widget.fill;
    _label = TextEditingController(text: fill?.label ?? '');
    _amount = TextEditingController(
      text: fill?.total == null ? '' : formatRoundedForInput(fill!.total!, 2),
    );
  }

  @override
  void dispose() {
    _label.dispose();
    _amount.dispose();
    super.dispose();
  }

  void _submit() {
    final label = _label.text.trim();
    if (label.isEmpty) return;
    Navigator.of(
      context,
    ).pop(_LineEdit(label: label, amount: parseUserDecimal(_amount.text)));
  }

  @override
  Widget build(BuildContext context) {
    final fill = widget.fill;
    return AlertDialog(
      title: Text(
        fill == null
            ? context.l10n.gasCalculators_blender_addManualLine
            : context.l10n.gasCalculators_blender_editLine(fill.label),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const Key('blender-line-description'),
            controller: _label,
            autofocus: true,
            decoration: InputDecoration(
              labelText: context.l10n.gasCalculators_blender_lineDescription,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('blender-line-amount'),
            controller: _amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: context.l10n.gasCalculators_blender_lineAmount,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.l10n.common_action_close),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(context.l10n.common_action_save),
        ),
      ],
    );
  }
}
