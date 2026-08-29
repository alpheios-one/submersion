import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/core/utils/currency.dart';
import 'package:submersion/core/utils/number_input.dart';
import 'package:submersion/core/utils/unit_formatter.dart';
import 'package:submersion/features/gas_calculators/presentation/providers/gas_blender_providers.dart';
import 'package:submersion/features/gas_calculators/presentation/widgets/blender/blender_formatting.dart';
import 'package:submersion/features/gas_calculators/presentation/widgets/blender/blender_section_title.dart';
import 'package:submersion/features/gas_calculators/presentation/widgets/blender/blender_volume_conversion.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// Billing defaults: currency and the three fill-gas prices.
///
/// Grouped under "Default settings and billing" behind the settings gear
/// (issue #1335): none of these change fill to fill the way the cylinder and
/// target mix do, so they no longer sit on the always-visible calculator.
class BlenderDefaultsCard extends ConsumerStatefulWidget {
  const BlenderDefaultsCard({super.key});

  @override
  ConsumerState<BlenderDefaultsCard> createState() =>
      _BlenderDefaultsCardState();
}

class _BlenderDefaultsCardState extends ConsumerState<BlenderDefaultsCard> {
  late final List<TextEditingController> _prices;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsProvider);
    _prices = [
      for (final p in ref.read(blenderGasPricesProvider))
        TextEditingController(
          text: p == null
              ? ''
              : formatRoundedForInput(_toDisplayPrice(p, settings), 2),
        ),
    ];
  }

  @override
  void dispose() {
    for (final c in _prices) {
      c.dispose();
    }
    super.dispose();
  }

  /// A price per 100 litres, shown as a price per 100 of the diver's unit.
  ///
  /// Gas priced at 7.99 per 100 cu ft is 0.28 per 100 L: the same gas, the
  /// same money, a unit that is 28 times larger. Storing the entered number
  /// without this conversion charged a cubic-foot diver 28 times over.
  static double _toDisplayPrice(double per100Liters, AppSettings s) =>
      isMetricVolume(s) ? per100Liters : per100Liters / cubicFeetPerLiter;

  static double _toPricePer100Liters(double shown, AppSettings s) =>
      isMetricVolume(s) ? shown : shown * cubicFeetPerLiter;

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final units = UnitFormatter(settings);
    final currency = ref.watch(blenderCurrencyProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            BlenderSectionTitle(context.l10n.gasCalculators_blender_defaults),
            _currencyField(context, currency),
            const SizedBox(height: 16),
            // One field per configured bank, always, rather than one per
            // step of any particular blend, matching the original billing
            // card behaviour (PR #1215 review).
            for (var slot = 0; slot < 3; slot++) ...[
              if (slot > 0) const SizedBox(height: 12),
              _priceField(context, slot, units),
            ],
          ],
        ),
      ),
    );
  }

  /// Read-only: issue #1335 follow-up removes the blender's own currency
  /// choice, so this always mirrors Settings -> Units -> Default currency
  /// rather than something edited here.
  Widget _currencyField(BuildContext context, String currency) {
    return InputDecorator(
      key: const Key('blender-currency-display'),
      decoration: InputDecoration(
        labelText: context.l10n.gasCalculators_blender_currency,
        helperText: context.l10n.gasCalculators_blender_currencyFollowsUnits,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      child: Text('$currency  ${currencySymbol(currency)}'),
    );
  }

  Widget _priceField(BuildContext context, int slot, UnitFormatter units) {
    final gas = ref.watch(
      [
        blenderFillGas1Provider,
        blenderFillGas2Provider,
        blenderFillGas3Provider,
      ][slot],
    );
    return TextField(
      controller: _prices[slot],
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
      decoration: InputDecoration(
        labelText:
            '${formatPreciseGasName(context, gas)}  '
            '${context.l10n.gasCalculators_blender_unitPrice(units.volumeSymbol)}',
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      onChanged: (_) {
        final settings = ref.read(settingsProvider);
        ref.read(blenderGasPricesProvider.notifier).state = [
          for (final c in _prices)
            switch (parseUserDecimal(c.text)) {
              final double entered => _toPricePer100Liters(entered, settings),
              null => null,
            },
        ];
      },
      onEditingComplete: () => saveBlenderPreferences(ref),
      onSubmitted: (_) => saveBlenderPreferences(ref),
    );
  }
}
