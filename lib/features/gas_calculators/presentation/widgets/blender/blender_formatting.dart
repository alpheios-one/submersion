import 'package:flutter/widgets.dart';
import 'package:submersion/core/constants/units.dart';
import 'package:submersion/features/dive_log/domain/entities/dive.dart'
    show GasMix;
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// Cubic feet in a litre, matching `VolumeUnit.convert`.
///
/// Storage is canonical: litres for volumes, currency per 100 litres for
/// prices. Every conversion to and from the diver's unit happens through
/// these functions, and nowhere else - both the billing card (where prices
/// are entered) and the invoice card (where a tariff summary reads them back)
/// share this one conversion path, because a second one is what once let the
/// volume column convert twice while the price never converted at all
/// (PR #1215 review).
const double kCubicFeetPerLiter = 0.0353147;

bool blenderMetric(AppSettings s) => s.volumeUnit == VolumeUnit.liters;

/// Litres to the diver's volume unit, for seeding a cylinder-volume field.
double blenderDisplayVolume(double liters, AppSettings s) =>
    blenderMetric(s) ? liters : liters * kCubicFeetPerLiter;

double blenderLitersFromDisplay(double shown, AppSettings s) =>
    blenderMetric(s) ? shown : shown / kCubicFeetPerLiter;

/// A price per 100 litres, shown as a price per 100 of the diver's unit.
///
/// Gas priced at 7.99 per 100 cu ft is 0.28 per 100 L: the same gas, the
/// same money, a unit that is 28 times larger. Storing the entered number
/// without this conversion charged a cubic-foot diver 28 times over.
double blenderDisplayPrice(double per100Liters, AppSettings s) =>
    blenderMetric(s) ? per100Liters : per100Liters / kCubicFeetPerLiter;

double blenderPricePer100Liters(double shown, AppSettings s) =>
    blenderMetric(s) ? shown : shown * kCubicFeetPerLiter;

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
