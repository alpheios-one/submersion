import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/constants/gas_consumption_display.dart';
import 'package:submersion/core/constants/units.dart';
import 'package:submersion/core/utils/unit_formatter.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';

/// Each consumption lane has a fixed unit family (spec D7): SAC follows the
/// pressure unit, RMV follows the volume unit, and neither reads the display
/// preference.
void main() {
  const metric = UnitFormatter(AppSettings());
  const imperial = UnitFormatter(
    AppSettings(
      pressureUnit: PressureUnit.psi,
      volumeUnit: VolumeUnit.cubicFeet,
    ),
  );

  group('SAC lane', () {
    test('sacSymbol follows the pressure unit', () {
      expect(metric.sacSymbol, 'bar/min');
      expect(imperial.sacSymbol, 'psi/min');
    });

    test('convertSac converts bar/min to the pressure unit', () {
      expect(metric.convertSac(1.5), closeTo(1.5, 1e-4));
      expect(imperial.convertSac(1.5), closeTo(21.7557, 1e-3));
    });

    test('formatSac uses one decimal for bar and none for psi', () {
      // psi/min values run in the hundreds; a decimal there is noise.
      expect(metric.formatSac(1.47), '1.5 bar/min');
      expect(imperial.formatSac(1.47), '21 psi/min');
    });
  });

  group('RMV lane', () {
    test('rmvSymbol follows the volume unit', () {
      expect(metric.rmvSymbol, 'L/min');
      expect(imperial.rmvSymbol, 'cuft/min');
    });

    test('convertRmv converts L/min to the volume unit', () {
      expect(metric.convertRmv(15.0), closeTo(15.0, 1e-4));
      expect(imperial.convertRmv(15.0), closeTo(0.5297, 1e-3));
    });

    test('formatRmv uses one decimal for liters and two for cubic feet', () {
      // cuft/min values sit below 1; one decimal renders every imperial
      // RMV as 0.5 or 0.6 (the unit_axis lesson).
      expect(metric.formatRmv(16.77), '16.8 L/min');
      expect(imperial.formatRmv(16.77), '0.59 cuft/min');
    });
  });

  test('the lanes ignore the display preference', () {
    const rmvOnly = UnitFormatter(
      AppSettings(gasConsumptionDisplay: GasConsumptionDisplay.rmv),
    );
    expect(rmvOnly.sacSymbol, 'bar/min');
    expect(rmvOnly.rmvSymbol, 'L/min');
  });
}
