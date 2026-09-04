import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/core/utils/currency.dart';
import 'package:submersion/core/utils/number_input.dart';
import 'package:submersion/core/utils/unit_formatter.dart';
import 'package:submersion/features/gas_calculators/domain/blending/billed_fill.dart';
import 'package:submersion/features/gas_calculators/domain/blending/blend_billing.dart';
import 'package:submersion/features/gas_calculators/domain/blending/blender_gas_role.dart';
import 'package:submersion/features/gas_calculators/domain/blending/flush_fee.dart';
import 'package:submersion/features/gas_calculators/presentation/providers/gas_blender_providers.dart';
import 'package:submersion/features/gas_calculators/presentation/widgets/blender/blender_formatting.dart';
import 'package:submersion/features/gas_calculators/presentation/widgets/blender/blender_section_title.dart';
import 'package:submersion/features/gas_calculators/presentation/widgets/blender/blender_volume_conversion.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/features/tank_presets/presentation/providers/tank_preset_providers.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// One entry in the cylinder-size dropdown, reduced to just what the row
/// needs to show and select. Every entry comes from the diver's global tank
/// presets (issue #1335 follow-up): the blender no longer keeps its own
/// cylinder-size vault, so renaming or deleting a size under Settings ->
/// Manage -> Tank Presets is renaming or deleting it here too.
class _CylinderChoice {
  const _CylinderChoice({required this.label, required this.liters})
    : isManageLink = false;

  /// The "manage cylinder sizes" entry appended after the presets: a marker
  /// rather than a null value, because [PopupMenuButton] reads a null
  /// selection as "dismissed without choosing" and never calls [onSelected]
  /// for it.
  const _CylinderChoice.manageLink()
    : label = '',
      liters = 0,
      isManageLink = true;

  final String label;
  final double liters;
  final bool isManageLink;
}

/// What the blend costs at the fill station's prices.
///
/// Placed after the safety note, as issue #1100 asks. The cylinder appears
/// only here: partial-pressure mixing is driven by pressure and needs no
/// cylinder, but a bill does.
class BlenderBillingCard extends ConsumerStatefulWidget {
  const BlenderBillingCard({super.key});

  @override
  ConsumerState<BlenderBillingCard> createState() => _BlenderBillingCardState();
}

class _BlenderBillingCardState extends ConsumerState<BlenderBillingCard> {
  late final TextEditingController _cylinder;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsProvider);
    final liters = ref.read(blenderCylinderLitersProvider);
    _cylinder = TextEditingController(
      text: formatRoundedForInput(litersToDisplayVolume(liters, settings), 2),
    );
  }

  @override
  void dispose() {
    _cylinder.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final units = UnitFormatter(settings);
    final billing = ref.watch(blenderBillingProvider);
    final currency = ref.watch(blenderCurrencyProvider);
    final decimals = pressureDecimalsFor(settings.pressureUnit);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            BlenderSectionTitle(context.l10n.gasCalculators_blender_billing),
            _cylinderRow(context, settings, units),
            const SizedBox(height: 20),
            const Divider(height: 1),
            const SizedBox(height: 12),
            _flushFeeSettings(context, settings, units),
            if (billing.lines.isNotEmpty) ...[
              const Divider(height: 28),
              for (final line in billing.lines)
                _costLine(context, line, units, settings, currency, decimals),
              const Divider(height: 20),
              _totalLine(context, billing, currency),
              const SizedBox(height: 8),
              Text(
                context.l10n.gasCalculators_blender_costBasis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  key: const Key('blender-save-fill'),
                  onPressed: () => _saveFill(context, billing, currency),
                  icon: const Icon(Icons.playlist_add, size: 18),
                  label: Text(context.l10n.gasCalculators_blender_saveFill),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Put the current blend on the running bill.
  ///
  /// The figures are frozen at save time rather than referenced: the next
  /// cylinder is about to replace this blend, and a bill has to survive that.
  void _saveFill(BuildContext context, BillingResult billing, String currency) {
    final target = ref.read(blenderTargetMixProvider);
    final label = formatPreciseMix(context, target);
    final fill = BilledFill(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      label: label,
      lines: [
        for (final line in billing.lines)
          BilledGasLine(
            gas: formatPreciseGasName(context, line.gas),
            addedBar: line.addedBar,
            cost: line.cost,
            freeGasLiters: line.freeGasLiters,
          ),
      ],
      total: billing.total,
    );
    ref.read(blenderBilledFillsProvider.notifier).state = appendCapped(
      ref.read(blenderBilledFillsProvider),
      fill,
    );
    saveBlenderPreferences(ref);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(context.l10n.gasCalculators_blender_fillAdded(label)),
      ),
    );
  }

  Widget _cylinderRow(
    BuildContext context,
    AppSettings settings,
    UnitFormatter units,
  ) {
    // Sourced from the diver's global tank presets (issue #1335 follow-up):
    // working pressure and material live on the preset too, but the blender
    // has no use for either, so only the display name and water volume cross
    // over.
    final presetsAsync = ref.watch(tankPresetsProvider);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextField(
            controller: _cylinder,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
            ],
            decoration: InputDecoration(
              labelText:
                  '${context.l10n.gasCalculators_blender_cylinderVolume} '
                  '(${units.volumeSymbol})',
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            onChanged: (v) =>
                ref.read(blenderCylinderLitersProvider.notifier).state =
                    displayVolumeToLiters(parseUserDecimal(v) ?? 0, settings),
            onEditingComplete: () => saveBlenderPreferences(ref),
            onSubmitted: (_) => saveBlenderPreferences(ref),
          ),
        ),
        const SizedBox(width: 8),
        // A cubic-foot diver does not know their cylinder's water capacity in
        // cubic feet (an AL80 is 0.39), so the presets fill it for them.
        presetsAsync.when(
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
          error: (error, stackTrace) => IconButton(
            icon: const Icon(Icons.error_outline),
            tooltip: context.l10n.gasCalculators_blender_cylinderPresets,
            onPressed: null,
          ),
          data: (presets) {
            final choices = [
              for (final preset in presets)
                _CylinderChoice(
                  label:
                      '${preset.displayName} '
                      '(${units.formatTankVolume(preset.volumeLiters, null)})',
                  liters: preset.volumeLiters,
                ),
            ];
            return PopupMenuButton<_CylinderChoice>(
              key: const Key('blender-cylinder-presets'),
              tooltip: context.l10n.gasCalculators_blender_cylinderPresets,
              position: PopupMenuPosition.under,
              itemBuilder: (context) => [
                for (final choice in choices)
                  PopupMenuItem<_CylinderChoice>(
                    value: choice,
                    child: Text(choice.label),
                  ),
                if (choices.isNotEmpty) const PopupMenuDivider(),
                // Last, directly under the list it manages (issue #1335
                // follow-up review): opens the global tank presets this
                // dropdown reads, since the blender no longer keeps its own
                // cylinder-size vault.
                PopupMenuItem<_CylinderChoice>(
                  key: const Key('blender-cylinder-sizes-link'),
                  value: const _CylinderChoice.manageLink(),
                  child: Row(
                    children: [
                      const Icon(Icons.straighten, size: 18),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          context
                              .l10n
                              .gasCalculators_blender_manageCylinderSizes,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              onSelected: (choice) {
                if (choice.isManageLink) {
                  context.push('/tank-presets');
                  return;
                }
                ref.read(blenderCylinderLitersProvider.notifier).state =
                    choice.liters;
                _cylinder.text = formatRoundedForInput(
                  litersToDisplayVolume(choice.liters, settings),
                  2,
                );
                saveBlenderPreferences(ref);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 12,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(context.l10n.gasCalculators_blender_cylinderPresets),
                    const Icon(Icons.arrow_drop_down),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _costLine(
    BuildContext context,
    GasCostLine line,
    UnitFormatter units,
    AppSettings settings,
    String currency,
    int decimals,
  ) {
    final style = Theme.of(context).textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: Text(formatPreciseGasName(context, line.gas), style: style),
          ),
          Expanded(
            flex: 4,
            child: Text(
              '+${units.formatPressure(line.addedBar, decimals: decimals)}',
              style: style,
              textAlign: TextAlign.end,
            ),
          ),
          Expanded(
            flex: 4,
            child: Text(
              // formatVolume converts litres to the diver's unit itself.
              // Converting first made a cubic-foot diver's column read zero.
              units.formatVolume(line.freeGasLiters),
              style: style,
              textAlign: TextAlign.end,
            ),
          ),
          Expanded(
            flex: 4,
            child: Text(
              line.cost == null ? '' : formatMoney(line.cost!, currency),
              style: style,
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }

  Widget _totalLine(
    BuildContext context,
    BillingResult billing,
    String currency,
  ) {
    final textTheme = Theme.of(context).textTheme;
    if (billing.total == null) {
      return Text(
        context.l10n.gasCalculators_blender_costMissingPrice,
        style: textTheme.bodyMedium?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          context.l10n.gasCalculators_blender_costTotal,
          style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        Text(
          formatMoney(billing.total!, currency),
          style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
        ),
      ],
    );
  }

  /// The hose-purge flat fee: whether it is charged, how often it appears on
  /// the bill, and each gas's volume and price, both entered on the Fill
  /// gases settings card and shown here as read-only text (issue #42
  /// follow-up). The bill itself reads the same setting for its own,
  /// likewise read-only, line.
  Widget _flushFeeSettings(
    BuildContext context,
    AppSettings settings,
    UnitFormatter units,
  ) {
    final enabled = ref.watch(blenderFlushFeeEnabledProvider);
    final mode = ref.watch(blenderFlushFeeModeProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          key: const Key('blender-flush-fee-enabled'),
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(context.l10n.gasCalculators_blender_flushFeeEnable),
          value: enabled,
          onChanged: (value) {
            ref.read(blenderFlushFeeEnabledProvider.notifier).state = value;
            saveBlenderPreferences(ref);
          },
        ),
        if (enabled) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: SegmentedButton<FlushFeeMode>(
              key: const Key('blender-flush-fee-mode'),
              segments: [
                ButtonSegment(
                  value: FlushFeeMode.perInvoice,
                  label: Text(
                    context.l10n.gasCalculators_blender_flushFeeModePerInvoice,
                  ),
                ),
                ButtonSegment(
                  value: FlushFeeMode.perFill,
                  label: Text(
                    context.l10n.gasCalculators_blender_flushFeeModePerFill,
                  ),
                ),
              ],
              selected: {mode},
              onSelectionChanged: (selection) {
                ref.read(blenderFlushFeeModeProvider.notifier).state =
                    selection.first;
                saveBlenderPreferences(ref);
              },
            ),
          ),
          for (var i = 0; i < BlenderGasRole.values.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            _flushFeeGasRow(context, ref, i, settings, units),
          ],
        ],
      ],
    );
  }

  Widget _flushFeeGasRow(
    BuildContext context,
    WidgetRef ref,
    int index,
    AppSettings settings,
    UnitFormatter units,
  ) {
    final role = BlenderGasRole.values[index];
    final label = blenderGasRoleLabel(context, role);
    final price = ref.watch(blenderGasPricesProvider)[index];
    final volumeLiters = ref
        .watch(blenderFlushFeeGasesProvider)[index]
        .volumeLiters;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Read-only: this role's purge volume is entered once, next to its
        // bank on the Fill gases settings (issue #42 follow-up), and shown
        // here as plain text rather than a second, easily-drifting entry
        // point for the same number -- the same treatment already given to
        // the price below. Plain text, not a disabled-looking field: an
        // InputDecorator still reads as an inert input control (issue #44
        // follow-up).
        Expanded(
          child: _flushFeeReadOnlyValue(
            context,
            key: Key('blender-flush-fee-volume-${role.name}'),
            label:
                '$label '
                '${context.l10n.gasCalculators_blender_flushFeeVolume} '
                '(${units.volumeSymbol})',
            value: formatRoundedForInput(
              litersToDisplayVolume(volumeLiters, settings),
              2,
            ),
          ),
        ),
        const SizedBox(width: 8),
        // Read-only: this role's price is entered once, next to its bank on
        // the Fill gases settings (issue #42), and shown here as plain text
        // rather than a second, easily-drifting entry point for the same
        // number.
        Expanded(
          child: _flushFeeReadOnlyValue(
            context,
            key: Key('blender-flush-fee-price-${role.name}'),
            label:
                '$label '
                '${context.l10n.gasCalculators_blender_unitPrice(units.volumeSymbol)}',
            value: price == null
                ? ''
                : formatRoundedForInput(
                    pricePer100LitersToDisplay(price, settings),
                    2,
                  ),
          ),
        ),
      ],
    );
  }

  /// A label/value pair rendered as plain text, no border or floating-label
  /// box -- the look already used for [_costLine] and [_totalLine], so a
  /// read-only figure never reads as an inert input control (issue #44
  /// follow-up).
  Widget _flushFeeReadOnlyValue(
    BuildContext context, {
    required Key key,
    required String label,
    required String value,
  }) {
    final theme = Theme.of(context);
    return Column(
      key: key,
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Text(value, style: theme.textTheme.bodyMedium),
      ],
    );
  }
}
