import 'package:flutter/widgets.dart';
import 'package:submersion/core/constants/units.dart';
import 'package:submersion/features/dive_log/domain/entities/dive.dart'
    show GasMix;
import 'package:submersion/features/gas_calculators/domain/blending/flush_fee.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// Decimals a blender's pressure is worth carrying, by unit.
///
/// A bar gauge resolves to a tenth, which is the precision issue #1100 asks
/// for ("207.6 bar"). A psi gauge does not, and "2900.8 psi" reads as noise
/// rather than precision.
int pressureDecimalsFor(PressureUnit unit) => unit == PressureUnit.bar ? 1 : 0;

/// One decimal, trailing ".0" trimmed.
///
/// Rounds before testing for a whole number: a blended mix lands on
/// 17.999999999 rather than 18, and an exact `== roundToDouble()` would print
/// that as "18.0" while an 18 typed by hand printed as "18".
String _trim(double v) {
  final rounded = (v * 10).round() / 10;
  return rounded == rounded.roundToDouble()
      ? rounded.toStringAsFixed(0)
      : rounded.toStringAsFixed(1);
}

/// A gas label that keeps its decimals, e.g. "Tx 8.3/73.4".
///
/// [GasMix.name] rounds through roundedO2/roundedHe, which is right for a
/// logbook and wrong at a fill station: a blender working to a tenth of a
/// percent cannot read their own target off a label that says "Tx 8/73".
String formatPreciseMix(BuildContext context, GasMix m) {
  if (m.isAir) return context.l10n.gasCalculators_blender_air;
  if (m.he >= 99.95) return context.l10n.gasCalculators_blender_helium;
  if (m.o2 >= 99.95) return 'O₂';
  if (m.he > 0) return 'Tx ${_trim(m.o2)}/${_trim(m.he)}';
  return 'EAN${_trim(m.o2)}';
}

/// The name to print for a fill gas. Same rules, kept as a separate entry
/// point so the call sites read as what they mean.
String formatPreciseGasName(BuildContext context, GasMix m) =>
    formatPreciseMix(context, m);

/// The label to print for a flush-fee gas identity.
String flushFeeGasLabel(BuildContext context, FlushFeeGasKind kind) =>
    switch (kind) {
      FlushFeeGasKind.o2 => context.l10n.gasCalculators_blender_o2,
      FlushFeeGasKind.he => context.l10n.gasCalculators_blender_helium,
      FlushFeeGasKind.air => context.l10n.gasCalculators_blender_air,
    };

/// Cubic feet in a litre, matching `VolumeUnit.convert`.
///
/// Storage is canonical: litres for volumes, currency per 100 litres for
/// prices. Every conversion to and from the diver's unit happens at the text
/// field, and nowhere else. A second, separately maintained copy of this
/// conversion is what let the volume column convert twice while the price
/// never converted at all (PR #1215 review), so every blender widget that
/// converts a volume or a price shares these functions rather than keeping
/// its own.
const double blenderCubicFeetPerLiter = 0.0353147;

bool blenderUsesMetricVolume(AppSettings s) =>
    s.volumeUnit == VolumeUnit.liters;

/// Litres to the diver's volume unit, for seeding a display field.
double blenderDisplayVolume(double liters, AppSettings s) =>
    blenderUsesMetricVolume(s) ? liters : liters * blenderCubicFeetPerLiter;

/// Inverse of [blenderDisplayVolume]: the diver's unit back to litres.
double blenderLitersFromDisplay(double shown, AppSettings s) =>
    blenderUsesMetricVolume(s) ? shown : shown / blenderCubicFeetPerLiter;

/// A price per 100 litres, shown as a price per 100 of the diver's unit.
///
/// Gas priced at 7.99 per 100 cu ft is 0.28 per 100 L: the same gas, the
/// same money, a unit that is 28 times larger. Storing the entered number
/// without this conversion charged a cubic-foot diver 28 times over.
double blenderDisplayPricePer100(double per100Liters, AppSettings s) =>
    blenderUsesMetricVolume(s)
    ? per100Liters
    : per100Liters / blenderCubicFeetPerLiter;

/// Inverse of [blenderDisplayPricePer100].
double blenderPricePer100FromDisplay(double shown, AppSettings s) =>
    blenderUsesMetricVolume(s) ? shown : shown * blenderCubicFeetPerLiter;
