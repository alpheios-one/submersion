import 'package:submersion/features/dive_log/domain/entities/dive.dart'
    show GasMix;
import 'package:submersion/features/gas_calculators/domain/gas_blender.dart';

/// What one fill gas contributes to the bill.
class GasCostLine {
  const GasCostLine({
    required this.gas,
    required this.addedBar,
    required this.freeGasLiters,
    required this.unitPricePer100,
    required this.cost,
  });

  final GasMix gas;

  /// Bar delivered for this gas, read at the fill temperature.
  final double addedBar;

  /// Free gas at the surface, in litres. Deliberately the ideal
  /// `water volume x bar`, see [computeBlendCost].
  final double freeGasLiters;

  /// Price per 100 litres, or null when the user has not priced this gas.
  final double? unitPricePer100;

  /// Null exactly when [unitPricePer100] is null.
  final double? cost;
}

class BillingResult {
  const BillingResult({required this.lines, required this.total});

  final List<GasCostLine> lines;

  /// Null when any line is unpriced, so a partial bill is never presented as
  /// a complete one.
  final double? total;
}

/// Price a fill procedure at [pricesPer100] per 100 litres of free gas, for a
/// cylinder of [waterLiters] water capacity.
///
/// The volume is the ideal `water volume x bar delivered`, regardless of which
/// equation of state the blend itself was solved with. That is on purpose: a
/// fill station meters by gauge pressure drop and charges for the pressure it
/// delivered, so the ideal figure is the commercial truth even where it is not
/// the physical one. Every line carries its [GasCostLine.addedBar] so the
/// arithmetic can be checked by hand against an invoice.
///
/// [pricesPer100] is positional against the fill steps. A short list, or a
/// null entry, leaves that line unpriced and the total null.
BillingResult computeBlendCost({
  required BlendResult blend,
  required double waterLiters,
  required List<double?> pricesPer100,
}) {
  final fills = blend.steps.where((s) => s.fillGas != null).toList();
  final volume = waterLiters <= 0 ? 0.0 : waterLiters;

  final lines = <GasCostLine>[];
  var total = 0.0;
  var complete = true;

  for (var i = 0; i < fills.length; i++) {
    final step = fills[i];
    final price = i < pricesPer100.length ? pricesPer100[i] : null;
    final liters = volume * step.addedBar;
    final cost = price == null ? null : liters / 100 * price;
    if (cost == null) {
      complete = false;
    } else {
      total += cost;
    }
    lines.add(
      GasCostLine(
        gas: step.fillGas!,
        addedBar: step.addedBar,
        freeGasLiters: liters,
        unitPricePer100: price,
        cost: cost,
      ),
    );
  }

  return BillingResult(lines: lines, total: complete ? total : null);
}
