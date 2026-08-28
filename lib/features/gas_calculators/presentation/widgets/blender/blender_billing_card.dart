import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/core/utils/currency.dart';
import 'package:submersion/core/utils/number_input.dart';
import 'package:submersion/core/utils/unit_formatter.dart';
import 'package:submersion/features/gas_calculators/domain/blending/billed_fill.dart';
import 'package:submersion/features/gas_calculators/domain/blending/blend_billing.dart';
import 'package:submersion/features/gas_calculators/presentation/pages/blender_settings_page.dart';
import 'package:submersion/features/gas_calculators/presentation/providers/gas_blender_providers.dart';
import 'package:submersion/features/gas_calculators/presentation/widgets/blender/blender_formatting.dart';
import 'package:submersion/features/gas_calculators/presentation/widgets/blender/blender_section_title.dart';
import 'package:submersion/features/gas_calculators/presentation/widgets/blender/blender_volume_conversion.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// One entry in the cylinder-size dropdown, reduced to just what the row
/// needs to show and select. Every entry comes from the diver's own saved
/// cylinder templates (issue #1335 follow-up): there is no separate,
/// hard-coded preset list any more, so renaming or deleting a size in
/// settings is renaming or deleting it here too.
class _CylinderChoice {
  const _CylinderChoice({required this.label, required this.liters});

  final String label;
  final double liters;
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
            // A Wrap rather than a Row: the heading and the action together
            // are a few pixels too wide for the narrowest phone, and dropping
            // the button to its own line reads better than truncating it.
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                BlenderSectionTitle(
                  context.l10n.gasCalculators_blender_billing,
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Opens the settings page scrolled straight to "Default
                    // settings and billing" rather than to its top, since
                    // that section's cylinder templates are what this card's
                    // dropdown reads (issue #1335 follow-up).
                    IconButton(
                      key: const Key('blender-billing-settings'),
                      icon: const Icon(Icons.settings_outlined),
                      tooltip: context.l10n.nav_settings,
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (context) =>
                              const BlenderSettingsPage(scrollToDefaults: true),
                        ),
                      ),
                    ),
                    if (billing.lines.isNotEmpty)
                      TextButton.icon(
                        key: const Key('blender-save-fill'),
                        onPressed: () => _saveFill(context, billing, currency),
                        icon: const Icon(Icons.playlist_add, size: 18),
                        label: Text(
                          context.l10n.gasCalculators_blender_saveFill,
                        ),
                      ),
                  ],
                ),
              ],
            ),
            _cylinderRow(context, settings, units),
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
    // Sourced entirely from Settings -> Default settings and billing
    // (issue #1335 follow-up): the blending-bench sizes seed that list on
    // first use, so there is nothing left to hard-code here.
    final choices = [
      for (final t in ref.watch(blenderCylinderTemplatesProvider))
        _CylinderChoice(
          label: '${t.name} (${units.formatTankVolume(t.liters, null)})',
          liters: t.liters,
        ),
    ];

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
        PopupMenuButton<_CylinderChoice>(
          key: const Key('blender-cylinder-presets'),
          tooltip: context.l10n.gasCalculators_blender_cylinderPresets,
          position: PopupMenuPosition.under,
          itemBuilder: (context) => [
            for (final choice in choices)
              PopupMenuItem<_CylinderChoice>(
                value: choice,
                child: Text(choice.label),
              ),
          ],
          onSelected: (choice) {
            ref.read(blenderCylinderLitersProvider.notifier).state =
                choice.liters;
            _cylinder.text = formatRoundedForInput(
              litersToDisplayVolume(choice.liters, settings),
              2,
            );
            saveBlenderPreferences(ref);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(context.l10n.gasCalculators_blender_cylinderPresets),
                const Icon(Icons.arrow_drop_down),
              ],
            ),
          ),
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
}
