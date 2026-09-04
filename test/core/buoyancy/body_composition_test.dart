import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/buoyancy/body_composition.dart';

void main() {
  group('BodyComposition.bmi', () {
    test('computes kilograms per square metre', () {
      expect(
        BodyComposition.bmi(weightKg: 80, heightCm: 175),
        closeTo(26.12, 0.01),
      );
    });

    test('is null without a height', () {
      expect(BodyComposition.bmi(weightKg: 80, heightCm: null), isNull);
    });

    test('rejects implausible heights and weights', () {
      expect(BodyComposition.bmi(weightKg: 80, heightCm: 60), isNull);
      expect(BodyComposition.bmi(weightKg: 80, heightCm: 300), isNull);
      expect(BodyComposition.bmi(weightKg: 0, heightCm: 175), isNull);
      expect(BodyComposition.bmi(weightKg: -5, heightCm: 175), isNull);
    });
  });

  group('BodyComposition.isPlausibleHeight', () {
    test('accepts the adult range and rejects the rest', () {
      expect(BodyComposition.isPlausibleHeight(100), isTrue);
      expect(BodyComposition.isPlausibleHeight(250), isTrue);
      expect(BodyComposition.isPlausibleHeight(99.9), isFalse);
      expect(BodyComposition.isPlausibleHeight(12.7), isFalse);
    });
  });

  group('BodyComposition.leadTermKg', () {
    test('is zero at the reference build the mass rule already assumes', () {
      expect(
        BodyComposition.leadTermKg(bodyMassKg: 80, heightCm: 175),
        closeTo(0, 1e-9),
      );
      expect(
        BodyComposition.leadTermKg(bodyMassKg: 100, heightCm: 175),
        closeTo(0, 1e-9),
      );
    });

    test('a shorter diver of equal mass needs more lead', () {
      // 80 kg at 165 cm is BMI 29.4 against 26.1 at the reference height:
      // 80 * 0.012 * 0.2 * (29.38 - 26.12) = 0.63 kg.
      expect(
        BodyComposition.leadTermKg(bodyMassKg: 80, heightCm: 165),
        closeTo(0.63, 0.02),
      );
    });

    test('a taller diver of equal mass needs less lead', () {
      // 100 kg at 195 cm is BMI 26.3 against 32.7: 100 * 0.0024 * -6.35.
      expect(
        BodyComposition.leadTermKg(bodyMassKg: 100, heightCm: 195),
        closeTo(-1.52, 0.03),
      );
    });

    test('is zero when the height is unknown or implausible', () {
      expect(BodyComposition.leadTermKg(bodyMassKg: 80, heightCm: null), 0);
      expect(BodyComposition.leadTermKg(bodyMassKg: 80, heightCm: 20), 0);
      expect(BodyComposition.leadTermKg(bodyMassKg: 0, heightCm: 175), 0);
    });
  });
}
