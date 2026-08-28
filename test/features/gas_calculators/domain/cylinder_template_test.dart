import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/features/gas_calculators/domain/blending/cylinder_template.dart';

void main() {
  group('CylinderTemplate', () {
    test('round-trips through JSON', () {
      const t = CylinderTemplate(name: 'Deco bottle', liters: 3);
      expect(CylinderTemplate.fromJson(t.toJson()), t);
    });

    test('is invalid with a blank name', () {
      expect(const CylinderTemplate(name: '  ', liters: 3).isValid, isFalse);
    });

    test('is invalid with a non-positive size', () {
      expect(const CylinderTemplate(name: 'x', liters: 0).isValid, isFalse);
      expect(const CylinderTemplate(name: 'x', liters: -1).isValid, isFalse);
    });

    test('a malformed entry is dropped on read', () {
      expect(CylinderTemplate.fromJson({'name': 'x'}), isNull);
      expect(CylinderTemplate.fromJson({'liters': 3}), isNull);
      expect(CylinderTemplate.fromJson({'name': 'x', 'liters': 0}), isNull);
      expect(CylinderTemplate.fromJson('not a map'), isNull);
    });

    test('the seeded blending-bench sizes are all valid', () {
      for (final t in CylinderTemplate.seedTemplates) {
        expect(t.isValid, isTrue, reason: t.toString());
      }
    });

    test('equal templates hash the same, so a Set dedupes them', () {
      const a = CylinderTemplate(name: 'Deco bottle', liters: 3);
      // Built from a decoded map rather than a second const literal, so this
      // is a distinct instance rather than the same canonicalized constant --
      // otherwise a Set of the two would trivially hold one element even with
      // a broken hashCode.
      final b = CylinderTemplate.fromJson(a.toJson())!;
      expect(a.hashCode, b.hashCode);
      expect({a, b}, hasLength(1));
    });
  });

  group('cylinderTemplateRejectionFor', () {
    test('accepts a fresh, valid template', () {
      const candidate = CylinderTemplate(name: 'Deco bottle', liters: 3);
      expect(cylinderTemplateRejectionFor(const [], candidate), isNull);
    });

    test('names an invalid template', () {
      const candidate = CylinderTemplate(name: '', liters: 3);
      expect(
        cylinderTemplateRejectionFor(const [], candidate),
        CylinderTemplateRejection.invalid,
      );
    });

    test('names a duplicate', () {
      const existing = CylinderTemplate(name: 'Deco bottle', liters: 3);
      expect(
        cylinderTemplateRejectionFor(const [existing], existing),
        CylinderTemplateRejection.duplicate,
      );
    });

    test('names the cap', () {
      final full = List.generate(
        kMaxCylinderTemplates,
        (i) => CylinderTemplate(name: 'Bottle $i', liters: 3 + i * 0.1),
      );
      expect(
        cylinderTemplateRejectionFor(
          full,
          const CylinderTemplate(name: 'One more', liters: 5),
        ),
        CylinderTemplateRejection.limitReached,
      );
    });
  });
}
