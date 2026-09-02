/// Body-composition estimate for weight prediction: how much of the
/// diver's own buoyancy the mass-only rule of thumb misses once height is
/// known.
///
/// Fat tissue (~0.9 kg/L) floats while lean tissue (~1.1 kg/L) sinks, so two
/// divers of equal mass can need noticeably different lead. Body mass index
/// is the cheapest proxy for the fat fraction the app can compute from the
/// profile, and the term is deliberately small: it refines the personal
/// baseline rather than replacing it, and logged history overrides both.
///
/// Sign convention matches the rest of the engine: positive = more lead.
class BodyComposition {
  /// Breakdown-term key shared by the engine, the twin assembler, and the
  /// widgets that localize it.
  static const String termLabel = 'bmi';

  /// The height the mass-only personal prior implicitly assumes. At this
  /// height the term is zero, so divers of average build see no change.
  static const double referenceHeightCm = 175.0;

  /// Plausibility bounds for an adult diver's height; anything outside is
  /// treated as unknown rather than fed into a squared denominator.
  static const double minHeightCm = 100.0;
  static const double maxHeightCm = 250.0;

  /// Body-fat fraction change per BMI unit (Deurenberg et al., 1991: about
  /// 1.2 percentage points per unit for adults, sex and age aside).
  static const double fatFractionPerBmiUnit = 0.012;

  /// Lead-equivalent buoyancy of one kilogram of fat in place of one
  /// kilogram of lean tissue: 1/0.9 - 1/1.1 L, at roughly 1 kg/L of water.
  static const double leadPerKgFatSwap = 0.2;

  /// Whether a height is within the adult plausibility bounds.
  static bool isPlausibleHeight(double heightCm) =>
      heightCm >= minHeightCm && heightCm <= maxHeightCm;

  /// Body mass index (kg/m^2), or null when either input is missing or
  /// implausible.
  static double? bmi({required double weightKg, required double? heightCm}) {
    if (heightCm == null || weightKg <= 0) return null;
    if (!isPlausibleHeight(heightCm)) return null;
    final heightM = heightCm / 100.0;
    return weightKg / (heightM * heightM);
  }

  /// Extra lead (kg) attributable to body composition, relative to the
  /// build the mass rule assumes: zero at [referenceHeightCm], positive for
  /// a shorter (higher-BMI) diver of the same mass, negative for a taller
  /// one. Zero when BMI cannot be computed.
  static double leadTermKg({
    required double bodyMassKg,
    required double? heightCm,
  }) {
    final actual = bmi(weightKg: bodyMassKg, heightCm: heightCm);
    if (actual == null) return 0.0;
    final reference = bmi(weightKg: bodyMassKg, heightCm: referenceHeightCm)!;
    return bodyMassKg *
        fatFractionPerBmiUnit *
        leadPerKgFatSwap *
        (actual - reference);
  }
}
