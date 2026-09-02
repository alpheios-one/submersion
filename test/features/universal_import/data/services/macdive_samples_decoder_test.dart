import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:submersion/features/universal_import/data/services/macdive_samples_decoder.dart';
import 'package:submersion/features/universal_import/data/services/macdive_sqlite_sample.dart';

/// Three samples encoded by a Python port of MacDive's own encoder, so these
/// fixtures pin the byte layout independently of the Dart decoder. The
/// Python encoder reproduced, byte for byte, ciphertext signatures observed
/// in real `ZSAMPLES` blobs, and its decoder matched MacDive's UDDF export
/// sample-for-sample across a 540-dive library.
///
/// Sample values, in record order: time, depth, then the optional fields.
///
/// | time | depth | air  | air2 | bpm | ndt | ppo2 | temp | nextStop | tts |
/// |------|-------|------|------|-----|-----|------|------|----------|-----|
/// | 0    | 0.0   | 3000 | 2900 | 70  | 99  | 0.21 | 27.5 | 0.0      | 0   |
/// | 10   | 5.5   | 2980 | 2890 | 75  | 60  | 0.32 | 26.0 | 3.0      | 1   |
/// | 20   | 12.25 | 2950 | 2880 | 80  | 30  | 0.47 | 24.5 | 6.0      | 2   |
const _allFields = // options 0xFF
    '04000000ff00000084b90aa09fbb1ecc2049c918d62c7ceba2affb6a442190266cb33c'
    '2fe1add77784b90aa09fbb1ecc661a89ab790cd3e69cf4906ecb6bcd3e30b58f041717'
    '4f2ebf550922123b3eaa8d9c9bc48edbbe43041b29d8446d86aa4ab20f9f62017bc2c7'
    '8d881caabedea6ed8ebab32e035bcba920838ad92b9ec65c84e51200fcc0d2';

/// Options 0x9D: pressure, NDT, ppO2, temperature and TTS. The layout of
/// every Shearwater Teric dive in the reference library.
const _tericFields =
    '040000009d00000084b90aa09fbb1ecc707a303efd5ca4136cb33c2fe1add7778982a2'
    '5a71ac47cc7712a88bff48c72d59c702e26818946bf577aa1d81920c4f041b29d8446d'
    '86aa539dacfb348f9599ed8ebab32e035bcb1bf1a889d25515a01095ad38eec6379a';

/// Options 0x10: temperature only.
const _temperatureOnly =
    '040000001000000084b90aa09fbb1ecc913727cb0760f109186d911e940f2f85041b29'
    'd8446d86aafb82d2151205e2abfb9239925fb6da76';

/// Options 0: bare time and depth.
const _timeAndDepth =
    '040000000000000084b90aa09fbb1ecc661a89ab790cd3e6041b29d8446d86aa242dfe'
    'ce0112c369';

/// Exactly what MacDive stores for a dive with an empty sample array: the
/// header plus one block holding the zero length.
const _empty = '040000000000000084b90aa09fbb1ecc';

Uint8List _hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

void main() {
  group('MacDiveSamplesDecoder', () {
    test('decodes every optional field in encoder order', () {
      final samples = MacDiveSamplesDecoder.decode(_hex(_allFields))!;
      expect(samples, hasLength(3));

      final MacDiveSqliteSample s = samples[1];
      expect(s.time, const Duration(seconds: 10));
      expect(s.depthMeters, closeTo(5.5, 1e-6));
      expect(s.pressure, closeTo(2980.0, 1e-3));
      expect(s.pressure2, closeTo(2890.0, 1e-3));
      expect(s.heartRate, 75);
      expect(s.ndtMinutes, 60);
      expect(s.ppO2, closeTo(0.32, 1e-6));
      expect(s.temperatureCelsius, closeTo(26.0, 1e-6));
      expect(s.nextStopDepthMeters, closeTo(3.0, 1e-6));
      expect(s.ttsMinutes, 1);

      expect(samples[2].time, const Duration(seconds: 20));
      expect(samples[2].depthMeters, closeTo(12.25, 1e-6));
      expect(samples[2].ttsMinutes, 2);
    });

    test('the options word selects which fields each record carries', () {
      final samples = MacDiveSamplesDecoder.decode(_hex(_tericFields))!;
      expect(samples, hasLength(3));
      final s = samples[2];
      expect(s.depthMeters, closeTo(12.25, 1e-6));
      expect(s.pressure, closeTo(2950.0, 1e-3));
      expect(s.ndtMinutes, 30);
      expect(s.ppO2, closeTo(0.47, 1e-6));
      expect(s.temperatureCelsius, closeTo(24.5, 1e-6));
      expect(s.ttsMinutes, 2);
      // Absent from the options word, so absent from the record.
      expect(s.pressure2, isNull);
      expect(s.heartRate, isNull);
      expect(s.nextStopDepthMeters, isNull);
    });

    test('a single optional field lands in the right slot', () {
      final samples = MacDiveSamplesDecoder.decode(_hex(_temperatureOnly))!;
      expect(samples.map((s) => s.temperatureCelsius), [27.5, 26.0, 24.5]);
      expect(samples.map((s) => s.pressure), [null, null, null]);
    });

    test('no options means bare time and depth records', () {
      final samples = MacDiveSamplesDecoder.decode(_hex(_timeAndDepth))!;
      expect(samples.map((s) => s.time.inSeconds), [0, 10, 20]);
      expect(samples.map((s) => s.depthMeters), [0.0, 5.5, 12.25]);
    });

    test('an empty sample array decodes to an empty list, not null', () {
      expect(MacDiveSamplesDecoder.decode(_hex(_empty)), isEmpty);
    });

    test('fractional seconds survive the float', () {
      final blob = _encode([
        [2.5, 1.0],
        [7.25, 2.0],
      ], options: 0);
      final samples = MacDiveSamplesDecoder.decode(blob)!;
      expect(samples.map((s) => s.time.inMilliseconds), [2500, 7250]);
    });

    test('versions 2 and 3 share the version 4 layout', () {
      for (final version in [2, 3]) {
        final blob = _encode([
          [0.0, 0.0],
          [5.0, 3.0],
        ], options: 0);
        ByteData.sublistView(blob).setUint32(0, version, Endian.little);
        final samples = MacDiveSamplesDecoder.decode(blob);
        expect(samples, isNotNull, reason: 'version $version');
        expect(samples!.last.depthMeters, 3.0);
      }
    });

    test('bits above the low byte of the options word are ignored', () {
      final blob = _encode([
        [0.0, 0.0],
        [5.0, 3.0],
      ], options: 0);
      ByteData.sublistView(blob).setUint32(4, 0x100, Endian.little);
      expect(MacDiveSamplesDecoder.decode(blob), hasLength(2));
    });

    test('a non-finite optional field is dropped, not fatal', () {
      // A bad reading inside a profile MacDive still displays: keep the
      // sample, lose the field.
      final blob = _encode([
        [0.0, 0.0, 27.5],
        [10.0, 5.5, double.nan],
        [20.0, 12.25, double.infinity],
      ], options: MacDiveSamplesDecoder.optionTemperature);
      final samples = MacDiveSamplesDecoder.decode(blob)!;
      expect(samples.map((s) => s.depthMeters), [0.0, 5.5, 12.25]);
      expect(samples.map((s) => s.temperatureCelsius), [27.5, null, null]);
    });

    test('version 1 records are unencrypted 24-byte fixed layouts', () {
      final blob = Uint8List(4 + 24 * 2);
      final data = ByteData.sublistView(blob);
      data.setUint32(0, 1, Endian.little);
      var offset = 4;
      for (final (time, depth, air, ndt, ppo2, temp) in [
        (0.0, 0.0, 200.0, 99, 0.21, 22.0),
        (30.0, 18.0, double.nan, 40, 0.59, 21.5),
      ]) {
        data.setFloat32(offset, time, Endian.little);
        data.setFloat32(offset + 4, depth, Endian.little);
        data.setFloat32(offset + 8, air, Endian.little);
        data.setInt32(offset + 12, ndt, Endian.little);
        data.setFloat32(offset + 16, ppo2, Endian.little);
        data.setFloat32(offset + 20, temp, Endian.little);
        offset += 24;
      }

      final samples = MacDiveSamplesDecoder.decode(blob)!;
      expect(samples, hasLength(2));
      final s = samples[1];
      expect(s.time, const Duration(seconds: 30));
      expect(s.depthMeters, 18.0);
      // Non-finite optional values are dropped here too.
      expect(s.pressure, isNull);
      expect(samples[0].pressure, 200.0);
      expect(s.ndtMinutes, 40);
      expect(s.ppO2, closeTo(0.59, 1e-6));
      expect(s.temperatureCelsius, 21.5);
      expect(s.heartRate, isNull);
      expect(s.ttsMinutes, isNull);
    });

    group('rejects', () {
      test('a blob too short to carry a version', () {
        expect(MacDiveSamplesDecoder.decode(Uint8List(3)), isNull);
      });

      test('an unknown version word', () {
        // The mapper test's long-standing stand-in for "some bytes": 64
        // bytes of 0x42 read as version 0x42424242.
        final blob = Uint8List.fromList(List.filled(64, 0x42));
        expect(MacDiveSamplesDecoder.decode(blob), isNull);
        final zero = Uint8List(16);
        expect(MacDiveSamplesDecoder.decode(zero), isNull);
      });

      test('a header with no body', () {
        expect(MacDiveSamplesDecoder.decode(_hex('0400000000000000')), isNull);
      });

      test('a body that is not whole cipher blocks', () {
        final blob = _hex(_timeAndDepth);
        expect(MacDiveSamplesDecoder.decode(blob.sublist(0, 20)), isNull);
      });

      test('a length trailer that overruns the buffer', () {
        // Corrupt the last cipher block: its plaintext becomes garbage whose
        // length word is almost certainly larger than the buffer.
        final blob = _hex(_timeAndDepth);
        blob[blob.length - 1] ^= 0xFF;
        expect(MacDiveSamplesDecoder.decode(blob), isNull);
      });

      test('a length word that reaches into the trailer block', () {
        // One 12-byte temperature record needs three blocks from MacDive's
        // encoder: the record, its padding, and the trailer block. Two blocks
        // with a length of 12 would read the trailer's own first word as the
        // temperature, so the run must end before the trailer block.
        final plain = Uint8List(16);
        ByteData.sublistView(plain)
          ..setFloat32(0, 0.0, Endian.little)
          ..setFloat32(4, 3.0, Endian.little)
          ..setFloat32(8, 21.0, Endian.little)
          ..setUint32(12, 12, Endian.little);
        final blob = Uint8List(8 + plain.length);
        ByteData.sublistView(blob)
          ..setUint32(0, 4, Endian.little)
          ..setUint32(
            4,
            MacDiveSamplesDecoder.optionTemperature,
            Endian.little,
          );
        blob.setRange(
          8,
          blob.length,
          MacDiveSamplesDecoder.cipher.encrypt(plain),
        );
        expect(MacDiveSamplesDecoder.decode(blob), isNull);
      });

      test('a record run that is not a whole number of records', () {
        final blob = _encode([
          [0.0, 0.0],
          [5.0, 3.0],
        ], options: 0);
        // Claim pressure is present: the stride becomes 12, which does not
        // divide the 16-byte run.
        ByteData.sublistView(
          blob,
        ).setUint32(4, MacDiveSamplesDecoder.optionPressure, Endian.little);
        expect(MacDiveSamplesDecoder.decode(blob), isNull);
      });

      test('a non-finite time or depth', () {
        final blob = _encode([
          [0.0, 0.0],
          [double.nan, 3.0],
        ], options: 0);
        expect(MacDiveSamplesDecoder.decode(blob), isNull);
      });

      test('a version 1 blob with a partial trailing record', () {
        // Version 1 has no length trailer, so whole records are the only
        // structural guarantee; a torn record must not decode as a prefix.
        final blob = Uint8List(4 + 24 + 10);
        ByteData.sublistView(blob).setUint32(0, 1, Endian.little);
        expect(MacDiveSamplesDecoder.decode(blob), isNull);
        expect(MacDiveSamplesDecoder.decode(blob.sublist(0, 28)), hasLength(1));
      });
    });
  });
}

/// Encodes float-only records the way MacDive's encoder does: pack each
/// record's 32-bit floats back to back, pad to a block boundary, append a
/// block whose last word is the byte length of the packed run, then TEA-ECB
/// the lot under the app key. Every record must have the same width.
Uint8List _encode(List<List<double>> records, {required int options}) {
  final width = records.isEmpty ? 0 : records.first.length * 4;
  final packed = Uint8List(records.length * width);
  final data = ByteData.sublistView(packed);
  for (var i = 0; i < records.length; i++) {
    for (var j = 0; j < records[i].length; j++) {
      data.setFloat32(i * width + j * 4, records[i][j], Endian.little);
    }
  }
  final blocks = (packed.length + 7) ~/ 8 + 1;
  final plain = Uint8List(blocks * 8)..setRange(0, packed.length, packed);
  ByteData.sublistView(
    plain,
  ).setUint32(plain.length - 4, packed.length, Endian.little);

  const cipher = MacDiveSamplesDecoder.cipher;
  final blob = Uint8List(8 + plain.length);
  ByteData.sublistView(blob)
    ..setUint32(0, 4, Endian.little)
    ..setUint32(4, options, Endian.little);
  blob.setRange(8, blob.length, cipher.encrypt(plain));
  return blob;
}
