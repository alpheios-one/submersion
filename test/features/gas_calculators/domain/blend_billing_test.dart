import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/features/dive_log/domain/entities/dive.dart'
    show GasMix;
import 'package:submersion/features/gas_calculators/domain/blending/blend_billing.dart';
import 'package:submersion/features/gas_calculators/domain/gas_blender.dart';

const _o2 = GasMix(o2: 100);
const _he = GasMix(o2: 0, he: 100);
const _air = GasMix(o2: 21);

BlendStep _step(GasMix? gas, double addedBar) => BlendStep(
  fillGas: gas,
  pressureBar: 0,
  addedBar: addedBar,
  resultingMix: _air,
  addedVolumePerLiter: gas == null ? null : addedBar,
);

BlendResult _blend(List<BlendStep> steps) =>
    BlendResult(steps: steps, settledPressureBar: 200);

void main() {
  group('computeBlendCost', () {
    test('reproduces the worked example from issue #936', () {
      final result = computeBlendCost(
        blend: _blend([
          _step(null, 0),
          _step(_o2, 7.3),
          _step(_he, 19.8),
          _step(_air, 48.1),
        ]),
        waterLiters: 3,
        pricesPer100: [2.00, 10.00, 0.10],
      );

      expect(result.lines, hasLength(3));
      expect(result.lines[0].cost, closeTo(0.438, 0.0005));
      expect(result.lines[1].cost, closeTo(5.94, 0.0005));
      expect(result.lines[2].cost, closeTo(0.1443, 0.0005));
      expect(result.total, closeTo(6.5223, 0.0005));
    });

    test('reproduces the helium example from issue #1100', () {
      final result = computeBlendCost(
        blend: _blend([_step(null, 0), _step(_he, 50)]),
        waterLiters: 3,
        pricesPer100: [7.99],
      );

      expect(result.lines.single.freeGasLiters, closeTo(150, 1e-9));
      expect(result.lines.single.cost, closeTo(11.985, 0.0005));
      expect(result.total, closeTo(11.985, 0.0005));
    });

    test('free gas is water volume times bar delivered', () {
      final result = computeBlendCost(
        blend: _blend([_step(null, 0), _step(_air, 48.1)]),
        waterLiters: 12,
        pricesPer100: [null],
      );
      expect(result.lines.single.freeGasLiters, closeTo(577.2, 1e-9));
      expect(result.lines.single.addedBar, closeTo(48.1, 1e-9));
    });

    test('the start step is not a billable line', () {
      final result = computeBlendCost(
        blend: _blend([_step(null, 0), _step(_o2, 10)]),
        waterLiters: 3,
        pricesPer100: [1.0],
      );
      expect(result.lines, hasLength(1));
      expect(result.lines.single.gas, _o2);
    });

    test('a missing price yields a null cost and a null total', () {
      final result = computeBlendCost(
        blend: _blend([_step(null, 0), _step(_o2, 10), _step(_air, 20)]),
        waterLiters: 3,
        pricesPer100: [2.0, null],
      );
      expect(result.lines[0].cost, closeTo(0.6, 1e-9));
      expect(result.lines[1].cost, isNull);
      expect(result.total, isNull);
    });

    test('a price list shorter than the step list prices what it can', () {
      final result = computeBlendCost(
        blend: _blend([_step(null, 0), _step(_o2, 10), _step(_air, 20)]),
        waterLiters: 3,
        pricesPer100: [2.0],
      );
      expect(result.lines[1].unitPricePer100, isNull);
      expect(result.total, isNull);
    });

    test('a non-positive cylinder volume prices nothing', () {
      final result = computeBlendCost(
        blend: _blend([_step(null, 0), _step(_o2, 10)]),
        waterLiters: 0,
        pricesPer100: [2.0],
      );
      expect(result.lines.single.freeGasLiters, 0);
      expect(result.lines.single.cost, 0);
      expect(result.total, 0);
    });
  });
}
