import 'package:flutter_test/flutter_test.dart';
import 'package:libdivecomputer_plugin/libdivecomputer_plugin.dart' as pigeon;
import 'package:submersion/features/universal_import/data/services/raw_profile_sanity_check.dart';

pigeon.ProfileSample _sample(int t, double depth) => pigeon.ProfileSample(
  timeSeconds: t,
  depthMeters: depth,
  temperatureCelsius: 20.0,
);

pigeon.ParsedDive _parsed({
  required List<pigeon.ProfileSample> samples,
  double maxDepthMeters = 0.0,
  int durationSeconds = 0,
}) => pigeon.ParsedDive(
  fingerprint: 'fp',
  dateTimeYear: 2026,
  dateTimeMonth: 1,
  dateTimeDay: 1,
  dateTimeHour: 10,
  dateTimeMinute: 0,
  dateTimeSecond: 0,
  maxDepthMeters: maxDepthMeters,
  avgDepthMeters: 0.0,
  durationSeconds: durationSeconds,
  samples: samples,
  tanks: const [],
  gasMixes: const [],
  events: const [],
);

/// A 30 m, 40 minute dive - the shape a correct parse produces.
pigeon.ParsedDive _plausibleDive() => _parsed(
  maxDepthMeters: 30.0,
  durationSeconds: 2400,
  samples: [
    _sample(0, 0.0),
    _sample(600, 30.0),
    _sample(1800, 18.0),
    _sample(2400, 0.0),
  ],
);

void main() {
  group('RawProfileSanityCheck', () {
    test('accepts an ordinary dive', () {
      expect(RawProfileSanityCheck.accepts(_plausibleDive()), isTrue);
    });

    test('accepts an ordinary dive that agrees with the recorded scalars', () {
      expect(
        RawProfileSanityCheck.accepts(
          _plausibleDive(),
          recordedMaxDepthMeters: 30.4,
          recordedDuration: const Duration(minutes: 41),
        ),
        isTrue,
      );
    });

    test('rejects a parse with no samples', () {
      // The macOS wrapper has been seen returning success with a zeroed dive.
      expect(
        RawProfileSanityCheck.accepts(_parsed(samples: const [])),
        isFalse,
      );
    });

    test('rejects a depth no dive reaches', () {
      expect(
        RawProfileSanityCheck.accepts(
          _parsed(samples: [_sample(0, 0.0), _sample(60, 900.0)]),
        ),
        isFalse,
      );
    });

    test('rejects a depth reported only in the summary field', () {
      // maxDepthMeters comes from a different libdivecomputer field than the
      // samples, so a misread header can blow the bound on its own.
      expect(
        RawProfileSanityCheck.accepts(
          _parsed(
            maxDepthMeters: 6000.0,
            samples: [_sample(0, 0.0), _sample(60, 12.0)],
          ),
        ),
        isFalse,
      );
    });

    test('rejects a duration no dive lasts', () {
      expect(
        RawProfileSanityCheck.accepts(
          _parsed(
            durationSeconds: 400000,
            samples: [_sample(0, 0.0), _sample(60, 12.0)],
          ),
        ),
        isFalse,
      );
    });

    test('rejects samples that move backwards in time', () {
      // libdivecomputer accumulates sample time as it walks the record stream,
      // so real profiles never do this; bytes read in the wrong format do.
      expect(
        RawProfileSanityCheck.accepts(
          _parsed(
            samples: [_sample(0, 0.0), _sample(600, 10.0), _sample(5, 8.0)],
          ),
        ),
        isFalse,
      );
      expect(
        RawProfileSanityCheck.accepts(
          _parsed(samples: [_sample(-5, 0.0), _sample(600, 10.0)]),
        ),
        isFalse,
      );
    });

    test('rejects a non-finite depth', () {
      // NaN compares false against everything, so a NaN depth slides past the
      // lower bound, never becomes the running maximum, and never trips the
      // upper bound either. Without an explicit finiteness check it reaches
      // the profile as a sample depth of NaN.
      expect(
        RawProfileSanityCheck.accepts(
          _parsed(samples: [_sample(0, 0.0), _sample(60, double.nan)]),
        ),
        isFalse,
      );
      expect(
        RawProfileSanityCheck.accepts(
          _parsed(maxDepthMeters: double.nan, samples: [_sample(0, 5.0)]),
        ),
        isFalse,
      );
      // Infinity propagates through comparisons correctly, so the ordinary
      // bounds already catch it. Pinned so a future rewrite of those bounds
      // cannot quietly lose it.
      for (final value in [double.infinity, double.negativeInfinity]) {
        expect(
          RawProfileSanityCheck.accepts(
            _parsed(samples: [_sample(0, 0.0), _sample(60, value)]),
          ),
          isFalse,
          reason: 'should reject $value',
        );
      }
    });

    test('a non-finite recorded scalar cannot reject anything', () {
      // Same rule as a missing one: it carries no information, so it must not
      // be allowed to veto an otherwise sound parse.
      expect(
        RawProfileSanityCheck.accepts(
          _plausibleDive(),
          recordedMaxDepthMeters: double.nan,
        ),
        isTrue,
      );
      expect(
        RawProfileSanityCheck.accepts(
          _plausibleDive(),
          recordedMaxDepthMeters: double.infinity,
        ),
        isTrue,
      );
    });

    test('rejects a depth far below the surface sign', () {
      expect(
        RawProfileSanityCheck.accepts(
          _parsed(samples: [_sample(0, 0.0), _sample(60, -240.0)]),
        ),
        isFalse,
      );
    });

    test('tolerates the slight negative depth a surface sample can show', () {
      expect(
        RawProfileSanityCheck.accepts(
          _parsed(
            durationSeconds: 600,
            samples: [_sample(0, -0.4), _sample(600, 12.0)],
          ),
        ),
        isTrue,
      );
    });

    test('rejects a parse that grossly contradicts the recorded depth', () {
      expect(
        RawProfileSanityCheck.accepts(
          _plausibleDive(),
          recordedMaxDepthMeters: 3.0,
        ),
        isFalse,
      );
    });

    test('rejects a parse that grossly contradicts the recorded duration', () {
      expect(
        RawProfileSanityCheck.accepts(
          _plausibleDive(),
          recordedDuration: const Duration(minutes: 2),
        ),
        isFalse,
      );
    });

    test('survives a source logbook read in the wrong depth unit', () {
      // MacDive routinely omits its units row, so a whole logbook can be read
      // as feet when it is metres (#912) - a 3.28x error in the recorded
      // scalar that says nothing about whether the raw bytes decoded. The
      // cross-check is deliberately loose enough to let that through.
      expect(
        RawProfileSanityCheck.accepts(
          _plausibleDive(),
          recordedMaxDepthMeters: 30.0 * 3.28084,
          recordedDuration: const Duration(minutes: 40),
        ),
        isTrue,
      );
      expect(
        RawProfileSanityCheck.accepts(
          _plausibleDive(),
          recordedMaxDepthMeters: 30.0 / 3.28084,
          recordedDuration: const Duration(minutes: 40),
        ),
        isTrue,
      );
    });

    test('rejects an all-surface profile the source says was a real dive', () {
      // Zero on the two sides means opposite things, which is why they are not
      // treated alike. A zero *recorded* scalar is MacDive saying it has no
      // value. A zero *parsed* depth is libdivecomputer asserting the diver
      // never left the surface, and against a recorded 30 m dive that is a
      // wrong-format parse, not a shallow one.
      final allSurface = _parsed(
        durationSeconds: 2400,
        samples: [_sample(0, 0.0), _sample(1200, 0.0), _sample(2400, 0.0)],
      );
      expect(
        RawProfileSanityCheck.accepts(
          allSurface,
          recordedMaxDepthMeters: 30.0,
          recordedDuration: const Duration(minutes: 40),
        ),
        isFalse,
      );
      // With nothing to contradict it, the same series is still accepted: the
      // cross-check is the only thing that can know better.
      expect(RawProfileSanityCheck.accepts(allSurface), isTrue);
    });

    test('rejects a zero-length profile the source says lasted an hour', () {
      // One sample at t = 0 with no duration field is the duration-side twin
      // of the case above.
      expect(
        RawProfileSanityCheck.accepts(
          _parsed(maxDepthMeters: 28.0, samples: [_sample(0, 28.0)]),
          recordedMaxDepthMeters: 30.0,
          recordedDuration: const Duration(minutes: 60),
        ),
        isFalse,
      );
    });

    test('a shallow recorded depth still tolerates a zero parse', () {
      // The floors exist because relative tolerance is meaningless at small
      // magnitudes; a 3 m recorded dive is not enough to call a 0 m parse
      // wrong.
      expect(
        RawProfileSanityCheck.accepts(
          _parsed(
            durationSeconds: 200,
            samples: [_sample(0, 0.0), _sample(200, 0.0)],
          ),
          recordedMaxDepthMeters: 3.0,
          recordedDuration: const Duration(minutes: 4),
        ),
        isTrue,
      );
    });

    test('a missing or zero recorded scalar cannot reject anything', () {
      expect(
        RawProfileSanityCheck.accepts(
          _plausibleDive(),
          recordedMaxDepthMeters: 0.0,
          recordedDuration: Duration.zero,
        ),
        isTrue,
      );
    });

    test('a short shallow dive is not rejected by the tolerance floor', () {
      // 4 m for 6 minutes against a recorded 3 m / 10 minutes: small absolute
      // numbers make relative tolerance meaningless, which is what the floors
      // are for.
      final shallow = _parsed(
        maxDepthMeters: 4.0,
        durationSeconds: 360,
        samples: [_sample(0, 0.0), _sample(180, 4.0), _sample(360, 0.0)],
      );
      expect(
        RawProfileSanityCheck.accepts(
          shallow,
          recordedMaxDepthMeters: 3.0,
          recordedDuration: const Duration(minutes: 10),
        ),
        isTrue,
      );
    });
  });
}
