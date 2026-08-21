import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:submersion/core/constants/units.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/core/utils/currency.dart';
import 'package:submersion/core/utils/number_input.dart';
import 'package:submersion/core/utils/unit_formatter.dart';
import 'package:submersion/features/gas_calculators/domain/blending/blend_billing.dart';
import 'package:submersion/features/gas_calculators/domain/tank_spec.dart';
import 'package:submersion/features/gas_calculators/presentation/providers/gas_blender_providers.dart';
import 'package:submersion/features/gas_calculators/presentation/widgets/blender/blender_formatting.dart';
import 'package:submersion/features/gas_calculators/presentation/widgets/blender/blender_section_title.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// Litres in a cubic foot. Storage is always litres; a cubic-foot diver prices
/// per 100 cu ft, which is the same arithmetic on a converted volume rather
/// than a second formula.
const double _litersPerCubicFoot = 28.3168;

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
  late final List<TextEditingController> _prices;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsProvider);
    final liters = ref.read(blenderCylinderLitersProvider);
    _cylinder = TextEditingController(
      text: formatRoundedForInput(_toDisplayVolume(liters, settings), 2),
    );
    _prices = [
      for (final p in ref.read(blenderGasPricesProvider))
        TextEditingController(
          text: p == null ? '' : formatRoundedForInput(p, 2),
        ),
    ];
  }

  @override
  void dispose() {
    _cylinder.dispose();
    for (final c in _prices) {
      c.dispose();
    }
    super.dispose();
  }

  static double _toDisplayVolume(double liters, AppSettings s) =>
      s.volumeUnit == VolumeUnit.liters ? liters : liters / _litersPerCubicFoot;

  static double _toLiters(double shown, AppSettings s) =>
      s.volumeUnit == VolumeUnit.liters ? shown : shown * _litersPerCubicFoot;

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
            const SizedBox(height: 16),
            _currencyField(context, currency),
            const SizedBox(height: 16),
            for (var i = 0; i < billing.lines.length; i++) ...[
              if (i > 0) const SizedBox(height: 12),
              _priceField(context, billing.lines[i], i, units),
            ],
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

  Widget _cylinderRow(
    BuildContext context,
    AppSettings settings,
    UnitFormatter units,
  ) {
    final choices = settings.volumeUnit == VolumeUnit.liters
        ? metricTankChoices()
        : imperialTankChoices();

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
                    _toLiters(parseUserDecimal(v) ?? 0, settings),
            onEditingComplete: () => saveBlenderPreferences(ref),
            onSubmitted: (_) => saveBlenderPreferences(ref),
          ),
        ),
        const SizedBox(width: 8),
        // A cubic-foot diver does not know their cylinder's water capacity in
        // cubic feet (an AL80 is 0.39), so the presets fill it for them.
        PopupMenuButton<TankSpec>(
          key: const Key('blender-cylinder-presets'),
          tooltip: context.l10n.gasCalculators_blender_cylinderPresets,
          position: PopupMenuPosition.under,
          itemBuilder: (context) => [
            for (final choice in choices)
              PopupMenuItem<TankSpec>(
                value: choice,
                child: Text(
                  units.formatTankVolume(
                    choice.waterVolumeLiters,
                    choice.workingPressureBar,
                    ratedCapacityCuft: choice.ratedCapacityCuft,
                  ),
                ),
              ),
          ],
          onSelected: (choice) {
            ref.read(blenderCylinderLitersProvider.notifier).state =
                choice.waterVolumeLiters;
            _cylinder.text = formatRoundedForInput(
              _toDisplayVolume(choice.waterVolumeLiters, settings),
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

  Widget _currencyField(BuildContext context, String currency) {
    return DropdownButtonFormField<String>(
      key: const Key('blender-currency'),
      initialValue: currency,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: context.l10n.gasCalculators_blender_currency,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      items: [
        for (final code in currencyCodesWith(currency))
          DropdownMenuItem(
            value: code,
            child: Text('$code  ${currencySymbol(code)}'),
          ),
      ],
      onChanged: (code) {
        if (code == null) return;
        ref.read(blenderCurrencyProvider.notifier).state = code;
        saveBlenderPreferences(ref);
      },
    );
  }

  Widget _priceField(
    BuildContext context,
    GasCostLine line,
    int index,
    UnitFormatter units,
  ) {
    return TextField(
      controller: _prices[index],
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
      decoration: InputDecoration(
        labelText:
            '${formatPreciseGasName(context, line.gas)}  '
            '${context.l10n.gasCalculators_blender_unitPrice(units.volumeSymbol)}',
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      onChanged: (_) {
        final prices = <double?>[
          for (final c in _prices) parseUserDecimal(c.text),
        ];
        ref.read(blenderGasPricesProvider.notifier).state = prices;
      },
      onEditingComplete: () => saveBlenderPreferences(ref),
      onSubmitted: (_) => saveBlenderPreferences(ref),
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
              units.formatVolume(
                _toDisplayVolume(line.freeGasLiters, settings),
              ),
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
