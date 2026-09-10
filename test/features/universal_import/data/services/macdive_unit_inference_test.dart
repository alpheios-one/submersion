import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/features/universal_import/data/services/macdive_raw_types.dart';
import 'package:submersion/features/universal_import/data/services/macdive_samples_decoder.dart';
import 'package:submersion/features/universal_import/data/services/macdive_unit_inference.dart';
import 'package:submersion/features/universal_import/data/services/macdive_xml_models.dart'
    show MacDiveUnitSystem;

MacDiveRawLogbook _logbook({
  String? unitsPreference,
  List<MacDiveRawTank> tanks = const [],
  List<MacDiveRawTankAndGas> tankAndGases = const [],
  List<MacDiveRawDive> dives = const [],
}) {
  return MacDiveRawLogbook(
    dives: dives,
    sitesByPk: const {},
    buddiesByPk: const {},
    tagsByPk: const {},
    gearByPk: const {},
    tanksByPk: {for (final t in tanks) t.pk: t},
    gasesByPk: const {},
    tankAndGases: tankAndGases,
    crittersByPk: const {},
    certifications: const [],
    serviceRecords: const [],
    events: const [],
    diveToBuddyPks: const {},
    diveToTagPks: const {},
    diveToGearPks: const {},
    diveToCritterPks: const {},
    unitsPreference: unitsPreference,
  );
}

MacDiveRawDive _dive(Uint8List samples, {int pk = 1}) =>
    MacDiveRawDive(pk: pk, uuid: 'dive-$pk', samplesBlob: samples);

/// A `ZSAMPLES` blob whose only optional field is pressure, encoded the way
/// MacDive does: records packed little-endian, padded to a TEA block, a
/// trailing block holding the byte length of the run, and the whole body
/// TEA-ECB encrypted under the app key. Local to this suite because the
/// decoder and mapper suites pin different record shapes with their own
/// encoders, and the point here is only that a pressure reaches the scan.
Uint8List _pressureSamples(List<double> pressures) {
  const stride = 12;
  final packed = Uint8List(pressures.length * stride);
  final data = ByteData.sublistView(packed);
  for (var i = 0; i < pressures.length; i++) {
    data
      ..setFloat32(i * stride, i * 10.0, Endian.little)
      ..setFloat32(i * stride + 4, 5.0, Endian.little)
      ..setFloat32(i * stride + 8, pressures[i], Endian.little);
  }
  final plain = Uint8List(((packed.length + 7) ~/ 8 + 1) * 8)
    ..setRange(0, packed.length, packed);
  ByteData.sublistView(
    plain,
  ).setUint32(plain.length - 4, packed.length, Endian.little);

  final blob = Uint8List(8 + plain.length);
  ByteData.sublistView(blob)
    ..setUint32(0, 4, Endian.little)
    ..setUint32(4, MacDiveSamplesDecoder.optionPressure, Endian.little);
  blob.setRange(8, blob.length, MacDiveSamplesDecoder.cipher.encrypt(plain));
  return blob;
}

MacDiveRawTankAndGas _fill(double start, double end) => MacDiveRawTankAndGas(
  diveFk: 1,
  tankFk: 1,
  gasFk: 1,
  airStart: start,
  airEnd: end,
);

void main() {
  group('MacDiveUnitInference.resolve', () {
    test('prefers MacDive\'s own declaration', () {
      // Even though these pressures look metric, the declaration wins.
      expect(
        MacDiveUnitInference.resolve(
          _logbook(unitsPreference: 'Imperial', tankAndGases: [_fill(200, 50)]),
        ),
        MacDiveUnitSystem.imperial,
      );
      expect(
        MacDiveUnitInference.resolve(_logbook(unitsPreference: 'Metric')),
        MacDiveUnitSystem.metric,
      );
    });

    test('falls back to inference when the row is missing', () {
      // The 540-dive reference library has no SystemOfUnits row at all, which
      // is what made 3118 psi import as 3118 bar (#912).
      expect(
        MacDiveUnitInference.resolve(
          _logbook(tankAndGases: [_fill(3118, 1138)]),
        ),
        MacDiveUnitSystem.imperial,
      );
    });
  });

  group('MacDiveUnitInference.infer', () {
    test('reads fill pressures as psi above the bar ceiling', () {
      expect(
        MacDiveUnitInference.infer(_logbook(tankAndGases: [_fill(3000, 700)])),
        MacDiveUnitSystem.imperial,
      );
    });

    test('reads fill pressures as bar below the ceiling', () {
      expect(
        MacDiveUnitInference.infer(_logbook(tankAndGases: [_fill(232, 60)])),
        MacDiveUnitSystem.metric,
      );
    });

    test('uses working pressure when no dive has fill data', () {
      expect(
        MacDiveUnitInference.infer(
          _logbook(
            tanks: const [
              MacDiveRawTank(pk: 1, uuid: 't', workingPressure: 3000),
            ],
          ),
        ),
        MacDiveUnitSystem.imperial,
      );
      expect(
        MacDiveUnitInference.infer(
          _logbook(
            tanks: const [
              MacDiveRawTank(pk: 1, uuid: 't', workingPressure: 232),
            ],
          ),
        ),
        MacDiveUnitSystem.metric,
      );
    });

    test('ignores zero pressures, which MacDive uses for "not set"', () {
      // Only the 232 bar entry carries information.
      expect(
        MacDiveUnitInference.infer(
          _logbook(
            tanks: const [
              MacDiveRawTank(pk: 1, uuid: 't1', workingPressure: 0),
              MacDiveRawTank(pk: 2, uuid: 't2', workingPressure: 232),
            ],
          ),
        ),
        MacDiveUnitSystem.metric,
      );
    });

    test('falls back to cylinder size: cubic feet vs litres', () {
      expect(
        MacDiveUnitInference.infer(
          _logbook(tanks: const [MacDiveRawTank(pk: 1, uuid: 't', size: 80)]),
        ),
        MacDiveUnitSystem.imperial,
      );
      expect(
        MacDiveUnitInference.infer(
          _logbook(tanks: const [MacDiveRawTank(pk: 1, uuid: 't', size: 12)]),
        ),
        MacDiveUnitSystem.metric,
      );
    });

    test('stays unknown when nothing carries a signal', () {
      // Passthrough beats a coin flip.
      expect(MacDiveUnitInference.infer(_logbook()), MacDiveUnitSystem.unknown);
    });

    group('ZSAMPLES pressures', () {
      test('answer for a library that records no cylinders', () {
        // Before this witness existed such a library resolved to unknown, and
        // every sample pressure was charted in whatever unit it was stored
        // in: #912 again, on a column that only became readable with the
        // ZSAMPLES decoder.
        expect(
          MacDiveUnitInference.infer(
            _logbook(
              dives: [
                _dive(_pressureSamples([3000, 2400])),
              ],
            ),
          ),
          MacDiveUnitSystem.imperial,
        );
        expect(
          MacDiveUnitInference.infer(
            _logbook(
              dives: [
                _dive(_pressureSamples([232, 60])),
              ],
            ),
          ),
          MacDiveUnitSystem.metric,
        );
      });

      test('rank below the cylinder columns, which cost nothing to read', () {
        expect(
          MacDiveUnitInference.infer(
            _logbook(
              tanks: const [
                MacDiveRawTank(pk: 1, uuid: 't', workingPressure: 232),
              ],
              dives: [
                _dive(_pressureSamples([3000])),
              ],
            ),
          ),
          MacDiveUnitSystem.metric,
        );
        expect(
          MacDiveUnitInference.infer(
            _logbook(
              tanks: const [MacDiveRawTank(pk: 1, uuid: 't', size: 12)],
              dives: [
                _dive(_pressureSamples([3000])),
              ],
            ),
          ),
          MacDiveUnitSystem.metric,
        );
      });

      test('of zero are "not set" here too', () {
        expect(
          MacDiveUnitInference.infer(
            _logbook(
              dives: [
                _dive(_pressureSamples([0, 0])),
              ],
            ),
          ),
          MacDiveUnitSystem.unknown,
        );
      });

      test('survive an unreadable blob earlier in the library', () {
        expect(
          MacDiveUnitInference.infer(
            _logbook(
              dives: [
                _dive(Uint8List.fromList(List.filled(64, 0x42))),
                _dive(_pressureSamples([3000]), pk: 2),
              ],
            ),
          ),
          MacDiveUnitSystem.imperial,
        );
      });

      test('past the scan limit are not read', () {
        // The documented cost of not decrypting a whole library to answer a
        // question the cylinder columns normally answer for free. The mapper
        // covers the gap by dropping sample pressures it cannot convert
        // rather than charting them raw.
        final dives = [
          for (var i = 0; i <= MacDiveUnitInference.sampleScanDiveLimit; i++)
            _dive(
              _pressureSamples(
                i < MacDiveUnitInference.sampleScanDiveLimit ? [0] : [3000],
              ),
              pk: i + 1,
            ),
        ];
        expect(
          MacDiveUnitInference.infer(_logbook(dives: dives)),
          MacDiveUnitSystem.unknown,
        );
      });

      test('stop the scan as soon as one can only be psi', () {
        // A reading above the ceiling settles it; nothing later can change
        // the answer, so the remaining blobs are never decrypted.
        final dives = [
          _dive(_pressureSamples([3000])),
          for (var i = 1; i <= MacDiveUnitInference.sampleScanDiveLimit; i++)
            _dive(_pressureSamples([0]), pk: i + 1),
        ];
        expect(
          MacDiveUnitInference.infer(_logbook(dives: dives)),
          MacDiveUnitSystem.imperial,
        );
      });
    });
  });
}
