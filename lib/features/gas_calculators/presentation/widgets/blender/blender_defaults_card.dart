import 'package:flutter/material.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/core/utils/currency.dart';
import 'package:submersion/features/gas_calculators/presentation/providers/gas_blender_providers.dart';
import 'package:submersion/features/gas_calculators/presentation/widgets/blender/blender_section_title.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// Billing defaults: currently just the diver's default currency.
///
/// Grouped under "Default settings and billing" behind the settings gear
/// (issue #1335): the fill-gas prices that used to live here moved next to
/// their fill-gas fields on [BlenderFillGasesCard] (Eric's PR #1359 review
/// point 3), since a price only ever means something next to the gas it
/// prices.
class BlenderDefaultsCard extends ConsumerWidget {
  const BlenderDefaultsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currency = ref.watch(blenderCurrencyProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            BlenderSectionTitle(context.l10n.gasCalculators_blender_defaults),
            _currencyField(context, currency),
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
}
