import 'package:flutter/material.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/core/utils/number_input.dart';
import 'package:submersion/features/gas_calculators/domain/gas_blender.dart';
import 'package:submersion/features/gas_calculators/presentation/widgets/blender/blender_field_parsing.dart';
import 'package:submersion/core/utils/unit_formatter.dart';
import 'package:submersion/features/dive_log/domain/entities/dive.dart'
    show GasMix;
import 'package:submersion/features/gas_calculators/presentation/providers/gas_blender_providers.dart';
import 'package:submersion/features/gas_calculators/presentation/widgets/blender/blender_formatting.dart';
import 'package:submersion/features/gas_calculators/presentation/widgets/blender/blender_mix_row.dart';
import 'package:submersion/features/gas_calculators/presentation/widgets/blender/blender_section_title.dart';
import 'package:submersion/features/gas_calculators/presentation/widgets/blender/blender_volume_conversion.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// The three banks the blender draws from, in fill order.
class BlenderFillGasesCard extends ConsumerWidget {
  const BlenderFillGasesCard({
    super.key,
    required this.o2Controllers,
    required this.heControllers,
    required this.priceControllers,
  });

  final List<TextEditingController> o2Controllers;
  final List<TextEditingController> heControllers;

  /// Price per 100 litres for each bank, positional against
  /// [blenderGasPricesProvider] (Eric's PR #1359 review point 3: the price
  /// sits next to the gas it prices rather than in a separate card).
  final List<TextEditingController> priceControllers;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final units = UnitFormatter(settings);
    final providers = [
      blenderFillGas1Provider,
      blenderFillGas2Provider,
      blenderFillGas3Provider,
    ];
    // Watched, not read: the row's leading label names the gas the bank
    // currently holds, so it has to rebuild the moment O2 or He changes
    // rather than only on the next mix/save.
    final gases = [for (final p in providers) ref.watch(p)];
    final labels = [for (final g in gases) formatPreciseGasName(context, g)];
    // Sized to the widest label of the three: "Helium" would otherwise claim
    // more of the row than "Air" or "O₂", pushing that row's O2/He fields out
    // of line with the other two.
    final leadingWidth = labels
        .map((l) => _labelWidth(context, l))
        .reduce((a, b) => a > b ? a : b);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            BlenderSectionTitle(context.l10n.gasCalculators_blender_fillGases),
            for (var i = 0; i < 3; i++) ...[
              if (i > 0) const SizedBox(height: 12),
              BlenderMixRow(
                pressureSymbol: units.pressureSymbol,
                leading: labels[i],
                leadingWidth: leadingWidth,
                o2Controller: o2Controllers[i],
                heController: heControllers[i],
                // A blank box keeps the value it had. See mixPercentOrKeep.
                onMix: () {
                  final current = ref.read(providers[i]);
                  ref.read(providers[i].notifier).state = GasMix(
                    o2: mixPercentOrKeep(o2Controllers[i].text, current.o2),
                    he: mixPercentOrKeep(heControllers[i].text, current.he),
                  );
                },
                onSave: () => saveBlenderPreferences(ref),
                // Surfaced here rather than only back on the calculator page:
                // computeBlend throws the same BlendError.invalidMix, but that
                // card is a navigation away from the field that caused it.
                errorText: isValidGasMix(gases[i])
                    ? null
                    : context.l10n.gasCalculators_blender_error_invalidMix,
                priceController: priceControllers[i],
                priceLabel: context.l10n.gasCalculators_blender_unitPrice(
                  units.volumeSymbol,
                ),
                onPriceChanged: (_) => _onPriceChanged(ref, settings),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Rebuilds the whole positional price list from every row's controller,
  /// the same "read every field, write the whole list" shape
  /// [BlenderDefaultsCard] used before the prices moved here.
  void _onPriceChanged(WidgetRef ref, AppSettings settings) {
    ref.read(blenderGasPricesProvider.notifier).state = [
      for (final c in priceControllers)
        switch (parseUserDecimal(c.text)) {
          final double entered => displayToPricePer100Liters(entered, settings),
          null => null,
        },
    ];
  }
}

/// The rendered width of [text] in the row's leading-label style, at the
/// device's current text scale.
double _labelWidth(BuildContext context, String text) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: Theme.of(context).textTheme.titleSmall),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
  )..layout();
  return painter.width;
}
