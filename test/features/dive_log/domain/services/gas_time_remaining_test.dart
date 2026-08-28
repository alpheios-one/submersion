import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/features/dive_log/domain/services/gas_time_remaining.dart';

/// Shearwater-style GTR: minutes at the current depth and SAC until a direct
/// 10 m/min ascent would surface with exactly the reserve pressure left.
///
/// Reference vector, worked by hand: 200 bar at 20 m, SAC 1.0 bar/min at the
/// surface, reserve 50 bar. Ascent gas = 1.0 * (20/10) * (1 + 20/20) = 4 bar,
/// usable = 200 - 50 - 4 = 146 bar, consumption at depth = 3 bar/min, so
/// GTR = 146 / 3 = 48.67 min = 2920 s.
void main() {
  /// Every [intervalSeconds] for [count] samples at a constant [depth], with
  /// the tank draining at [barPerMinuteAtDepth] from [startBar].
  ({List<double> depths, List<int> timestamps, List<double> pressures}) steady({
    int count = 121,
    int intervalSeconds = 10,
    double depth = 20.0,
    double startBar = 230.0,
    double barPerMinuteAtDepth = 3.0,
  }) {
    final timestamps = List<int>.generate(count, (i) => i * intervalSeconds);
    return (
      depths: List<double>.filled(count, depth),
      timestamps: timestamps,
      pressures: timestamps
          .map((t) => startBar - barPerMinuteAtDepth * t / 60)
          .toList(),
    );
  }

  group('calculateGtrCurve', () {
    test('steady 20 m at SAC 1 bar/min reads 48.7 min at 200 bar', () {
      final p = steady();
      final gtr = calculateGtrCurve(
        depths: p.depths,
        timestamps: p.timestamps,
        pressures: p.pressures,
        reserveBar: 50.0,
      );

      expect(gtr.length, p.depths.length);
      // t = 600 s: 230 - 3 * 10 = 200 bar.
      expect(p.pressures[60], closeTo(200.0, 1e-9));
      expect(gtr[60], isNotNull);
      expect(gtr[60]!, closeTo(2920, 1));
    });

    test('is blank until a full SAC window of history exists', () {
      final p = steady();
      final gtr = calculateGtrCurve(
        depths: p.depths,
        timestamps: p.timestamps,
        pressures: p.pressures,
        reserveBar: 50.0,
      );

      // 110 s of history: window not yet full.
      expect(gtr[11], isNull);
      // 120 s of history: first sample with a full window.
      expect(gtr[12], isNotNull);
    });

    test('is blank at the surface', () {
      final p = steady();
      final depths = List<double>.from(p.depths)..[60] = 0.5;
      final gtr = calculateGtrCurve(
        depths: depths,
        timestamps: p.timestamps,
        pressures: p.pressures,
        reserveBar: 50.0,
      );

      expect(gtr[60], isNull);
      expect(gtr[61], isNotNull);
    });

    test('is blank when pressure is not falling', () {
      final p = steady(barPerMinuteAtDepth: 0.0);
      final gtr = calculateGtrCurve(
        depths: p.depths,
        timestamps: p.timestamps,
        pressures: p.pressures,
        reserveBar: 50.0,
      );

      expect(gtr.every((v) => v == null), isTrue);
    });

    test('is blank while a deco ceiling exists', () {
      final p = steady();
      final ceilings = List<double>.filled(p.depths.length, 0.0)..[60] = 3.0;
      final gtr = calculateGtrCurve(
        depths: p.depths,
        timestamps: p.timestamps,
        pressures: p.pressures,
        reserveBar: 50.0,
        ceilings: ceilings,
      );

      expect(gtr[60], isNull);
      expect(gtr[59], isNotNull);
      expect(gtr[61], isNotNull);
    });

    test('clamps to zero once reserve plus ascent gas exceeds the tank', () {
      // 82 - 3 * 10 = 52 bar at t = 600 s: 52 - 50 - 4 < 0.
      final p = steady(startBar: 82.0);
      final gtr = calculateGtrCurve(
        depths: p.depths,
        timestamps: p.timestamps,
        pressures: p.pressures,
        reserveBar: 50.0,
      );

      expect(p.pressures[60], closeTo(52.0, 1e-9));
      expect(gtr[60], 0);
    });

    test('sparse samples anchor the window at the latest sample at or before '
        'its start', () {
      // Every 50 s: at t = 200 the window start (80 s) falls between samples,
      // so the drop is measured from t = 50 over 150 s. Consumption is still
      // 3 bar/min at depth, so SAC is 1.0; P(200) = 220 bar, usable 166 bar,
      // GTR = 166 / 3 = 55.33 min = 3320 s.
      final p = steady(count: 5, intervalSeconds: 50);
      final gtr = calculateGtrCurve(
        depths: p.depths,
        timestamps: p.timestamps,
        pressures: p.pressures,
        reserveBar: 50.0,
      );

      expect(gtr[0], isNull);
      expect(gtr[1], isNull);
      expect(gtr[2], isNull);
      expect(gtr[3], isNotNull);
      expect(gtr[4]!, closeTo(3320, 1));
    });

    test('throws on mismatched series lengths', () {
      expect(
        () => calculateGtrCurve(
          depths: const [20.0, 20.0],
          timestamps: const [0, 10, 20],
          pressures: const [200.0, 199.0],
          reserveBar: 50.0,
        ),
        throwsArgumentError,
      );
    });
  });
}
