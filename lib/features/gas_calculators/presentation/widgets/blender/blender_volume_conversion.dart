import 'package:submersion/core/constants/units.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';

/// Cubic feet in a litre, matching `VolumeUnit.convert`.
///
/// Storage is canonical: litres for volumes. Every conversion to and from the
/// diver's unit happens at the text field, and nowhere else -- shared here so
/// the cylinder field and the cylinder-template manager cannot drift apart
/// the way volume and price once did (PR #1215 review).
const double cubicFeetPerLiter = 0.0353147;

bool isMetricVolume(AppSettings settings) =>
    settings.volumeUnit == VolumeUnit.liters;

/// Litres to the diver's volume unit, for seeding a volume field.
double litersToDisplayVolume(double liters, AppSettings settings) =>
    isMetricVolume(settings) ? liters : liters * cubicFeetPerLiter;

/// The diver's volume unit back to litres, for storing a volume field.
double displayVolumeToLiters(double shown, AppSettings settings) =>
    isMetricVolume(settings) ? shown : shown / cubicFeetPerLiter;
