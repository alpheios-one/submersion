import 'dart:typed_data';

import 'package:submersion/features/universal_import/data/services/macdive_sqlite_sample.dart';
import 'package:submersion/features/universal_import/data/services/tea_block_cipher.dart';

/// Decodes MacDive's `ZDIVE.ZSAMPLES` column, the profile MacDive itself
/// draws for a dive.
///
/// The layout was recovered from MacDive 2.16.3's `MDSampleUtils` class
/// (`sampleDataForArrayOfSamples:withOptions:` writes it,
/// `sampleArrayFromDataV2:` reads it) and verified sample-for-sample against
/// MacDive's own UDDF and XML exports of a 540-dive library; see
/// `docs/import-formats/macdive-zsamples.md`.
///
/// ```text
/// u32le version   1, or 2..4 (every blob seen in the wild says 4)
/// u32le options   bitmask of the optional per-sample fields present
/// bytes body      TEA-ECB ciphertext, a whole number of 8-byte blocks
/// ```
///
/// The body decrypts under [cipher], whose key is a constant in the MacDive
/// binary, to a run of fixed-width little-endian records followed by zero
/// padding and, in the last four bytes of the buffer, the byte length of the
/// record run. Every record starts with `time` and `depth` as 32-bit floats
/// and then carries one 4-byte field per set options bit, in the fixed order
/// the reads in [_decodeV2] follow (which is not bit order).
///
/// Version 1 predates the encryption: the same 4-byte version word, then
/// unencrypted 24-byte records of time, depth, pressure, NDT, ppO2 and
/// temperature with no options word.
///
/// An earlier investigation concluded the column was AES under a per-dive
/// key. It is not: the "per-dive markers" it saw were ECB blocks of a fixed
/// key whose plaintext happened to repeat within a dive, and the CommonCrypto
/// imports it found belong to the app's zip-archive password support.
class MacDiveSamplesDecoder {
  const MacDiveSamplesDecoder._();

  /// TEA under the four key words MacDive compiles in. Public so tests can
  /// build blobs the same way MacDive's encoder does.
  static const cipher = TeaBlockCipher(0x86, 0x16, 0x80, 0x60);

  /// Options bits. Presence is all they encode; the fields themselves are
  /// laid out in the encoder's own order, not in bit order.
  static const int optionPressure = 1 << 0;
  static const int optionHeartRate = 1 << 1;
  static const int optionNdt = 1 << 2;
  static const int optionPpO2 = 1 << 3;
  static const int optionTemperature = 1 << 4;
  static const int optionPressure2 = 1 << 5;
  static const int optionNextStopDepth = 1 << 6;
  static const int optionTts = 1 << 7;

  /// Only the low byte of the options word selects fields; MacDive's decoder
  /// tests bits 0 to 7 and nothing above.
  static const int _optionMask = 0xFF;

  static const int _headerLength = 8;
  static const int _baseRecordLength = 8;
  static const int _fieldLength = 4;

  /// Decodes [blob]. Returns null when the bytes are not a MacDive sample
  /// blob this decoder understands or fail its structural checks, so a
  /// corrupt or foreign column never turns into a plausible-looking profile.
  /// An empty list means MacDive stored a profile with no samples.
  ///
  /// Time and depth must be finite for the blob to be accepted at all. An
  /// optional field that is not finite is dropped from its sample instead:
  /// that is a bad reading inside a profile MacDive still displays, not a
  /// sign the blob is foreign.
  static List<MacDiveSqliteSample>? decode(Uint8List blob) {
    if (blob.length < 4) return null;
    final version = ByteData.sublistView(blob).getUint32(0, Endian.little);
    if (version == 1) return _decodeV1(blob);
    if (version < 2 || version > 4) return null;
    return _decodeV2(blob);
  }

  static List<MacDiveSqliteSample>? _decodeV2(Uint8List blob) {
    if (blob.length < _headerLength) return null;
    final options =
        ByteData.sublistView(blob).getUint32(4, Endian.little) & _optionMask;
    final body = Uint8List.sublistView(blob, _headerLength);
    if (body.isEmpty || body.length % TeaBlockCipher.blockSize != 0) {
      return null;
    }

    final plain = cipher.decrypt(body);
    final plainData = ByteData.sublistView(plain);
    final length = plainData.getUint32(plain.length - 4, Endian.little);
    if (length > plain.length - 4) return null;

    final stride = _baseRecordLength + _fieldLength * _bitCount(options);
    if (length % stride != 0) return null;

    final samples = <MacDiveSqliteSample>[];
    for (var offset = 0; offset < length; offset += stride) {
      final record = _RecordReader(plainData, offset, options);
      final time = record.float();
      final depth = record.float();
      if (!time.isFinite || !depth.isFinite) return null;
      // The optional fields, in the order MacDive's encoder emits them,
      // straight from the disassembly. Each read advances only when its bit
      // is set.
      final pressure = record.optionalFloat(optionPressure);
      final pressure2 = record.optionalFloat(optionPressure2);
      final heartRate = record.optionalInt32(optionHeartRate);
      final ndt = record.optionalInt32(optionNdt);
      final ppO2 = record.optionalFloat(optionPpO2);
      final temperature = record.optionalFloat(optionTemperature);
      final nextStop = record.optionalFloat(optionNextStopDepth);
      final tts = record.optionalInt32(optionTts);
      samples.add(
        MacDiveSqliteSample(
          time: _duration(time),
          depthMeters: depth,
          pressure: pressure,
          pressure2: pressure2,
          heartRate: heartRate,
          ndtMinutes: ndt,
          ppO2: ppO2,
          temperatureCelsius: temperature,
          nextStopDepthMeters: nextStop,
          ttsMinutes: tts,
        ),
      );
    }
    return samples;
  }

  static const int _v1HeaderLength = 4;
  static const int _v1RecordLength = 24;

  static List<MacDiveSqliteSample>? _decodeV1(Uint8List blob) {
    // No length trailer in this version, so the only structural check is
    // that the bytes divide into whole records.
    if ((blob.length - _v1HeaderLength) % _v1RecordLength != 0) return null;
    final data = ByteData.sublistView(blob);
    final samples = <MacDiveSqliteSample>[];
    for (
      var offset = _v1HeaderLength;
      offset + _v1RecordLength <= blob.length;
      offset += _v1RecordLength
    ) {
      final record = _RecordReader(data, offset, 0);
      final time = record.float();
      final depth = record.float();
      if (!time.isFinite || !depth.isFinite) return null;
      samples.add(
        MacDiveSqliteSample(
          time: _duration(time),
          depthMeters: depth,
          pressure: record.finiteFloat(),
          ndtMinutes: record.int32(),
          ppO2: record.finiteFloat(),
          temperatureCelsius: record.finiteFloat(),
        ),
      );
    }
    return samples;
  }

  static Duration _duration(double seconds) =>
      Duration(milliseconds: (seconds * 1000).round());

  /// Number of set bits in [v]; one 4-byte field per set option bit.
  static int _bitCount(int v) {
    var count = 0;
    for (var rest = v; rest != 0; rest &= rest - 1) {
      count++;
    }
    return count;
  }
}

/// Sequential little-endian reads through one record.
class _RecordReader {
  _RecordReader(this._data, this._offset, this._options);

  final ByteData _data;
  final int _options;
  int _offset;

  double float() {
    final v = _data.getFloat32(_offset, Endian.little);
    _offset += 4;
    return v;
  }

  int int32() {
    final v = _data.getInt32(_offset, Endian.little);
    _offset += 4;
    return v;
  }

  /// A float that is null when it is not a number MacDive could have shown.
  double? finiteFloat() {
    final v = float();
    return v.isFinite ? v : null;
  }

  /// Reads a float only when [bit] is set in the record's options word.
  double? optionalFloat(int bit) =>
      (_options & bit) != 0 ? finiteFloat() : null;

  /// Reads an int only when [bit] is set in the record's options word.
  int? optionalInt32(int bit) => (_options & bit) != 0 ? int32() : null;
}
