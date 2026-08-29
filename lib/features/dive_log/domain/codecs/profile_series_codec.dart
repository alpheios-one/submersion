import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:submersion/features/dive_log/domain/codecs/byte_io.dart';
import 'package:submersion/features/dive_log/domain/codecs/profile_sample.dart';
import 'package:submersion/features/dive_log/domain/codecs/profile_series_codec_exception.dart';
import 'package:submersion/features/dive_log/domain/codecs/profile_series_summary.dart';

/// How a field's column block is written.
enum ProfileFieldKind {
  /// Zigzag varint of the difference from the previous present value; the
  /// previous value starts at 0 for each block.
  deltaInt,

  /// IEEE-754 binary64, little-endian.
  float64,

  /// Runs of identical strings: run count, then (length, UTF-8 length,
  /// UTF-8 bytes) per run, covering the present values only.
  runLengthString,
}

/// One entry of a field table. [name] is the `dive_profiles` column name.
class ProfileField {
  const ProfileField(this.name, this.kind);

  final String name;
  final ProfileFieldKind kind;
}

/// The bytes and scalars a `dive_profile_series` row stores.
class EncodedProfileSeries {
  const EncodedProfileSeries({
    required this.bytes,
    required this.codecVersion,
    required this.summary,
  });

  final Uint8List bytes;
  final int codecVersion;
  final ProfileSeriesSummary summary;
}

/// Packs a series of [ProfileSample]s into one zlib-compressed columnar blob
/// and back. Lossless.
///
/// Layout of the uncompressed body: a version byte, the sample count as a
/// varint, then one column block per entry of that version's field table in
/// table order. See `byte_io.dart` for the block format.
///
/// Versioning: a later codec appends fields under a new version byte. The
/// decoder selects the field table by the blob's version byte, so an older
/// blob decodes under a newer codec with its missing fields null. A version
/// this codec does not know is refused.
class ProfileSeriesCodec {
  const ProfileSeriesCodec({this.fieldTables = const {version: fieldTableV1}});

  /// The version new blobs are written with.
  static const int version = 1;

  /// Codec v1: every `dive_profiles` sample column, in this order. Never
  /// reorder or remove an entry; append under a new version instead.
  static const List<ProfileField> fieldTableV1 = [
    ProfileField('timestamp', ProfileFieldKind.deltaInt),
    ProfileField('depth', ProfileFieldKind.float64),
    ProfileField('pressure', ProfileFieldKind.float64),
    ProfileField('temperature', ProfileFieldKind.float64),
    ProfileField('heart_rate', ProfileFieldKind.deltaInt),
    ProfileField('ascent_rate', ProfileFieldKind.float64),
    ProfileField('ceiling', ProfileFieldKind.float64),
    ProfileField('ndl', ProfileFieldKind.deltaInt),
    ProfileField('setpoint', ProfileFieldKind.float64),
    ProfileField('pp_o2', ProfileFieldKind.float64),
    ProfileField('o2_sensor1', ProfileFieldKind.float64),
    ProfileField('o2_sensor2', ProfileFieldKind.float64),
    ProfileField('o2_sensor3', ProfileFieldKind.float64),
    ProfileField('o2_sensor4', ProfileFieldKind.float64),
    ProfileField('o2_sensor5', ProfileFieldKind.float64),
    ProfileField('o2_sensor6', ProfileFieldKind.float64),
    ProfileField('cns', ProfileFieldKind.float64),
    ProfileField('tts', ProfileFieldKind.deltaInt),
    ProfileField('rbt', ProfileFieldKind.deltaInt),
    ProfileField('deco_type', ProfileFieldKind.deltaInt),
    ProfileField('heart_rate_source', ProfileFieldKind.runLengthString),
    ProfileField('heading', ProfileFieldKind.float64),
    ProfileField('o2_sensor_mv1', ProfileFieldKind.deltaInt),
    ProfileField('o2_sensor_mv2', ProfileFieldKind.deltaInt),
    ProfileField('o2_sensor_mv3', ProfileFieldKind.deltaInt),
    ProfileField('o2_sensor_mv4', ProfileFieldKind.deltaInt),
    ProfileField('o2_sensor_mv5', ProfileFieldKind.deltaInt),
    ProfileField('o2_sensor_mv6', ProfileFieldKind.deltaInt),
  ];

  /// Field table per version byte this codec can read.
  final Map<int, List<ProfileField>> fieldTables;

  static final ZLibCodec _zlib = ZLibCodec(level: 6);

  /// Encodes a non-empty, timestamp-ordered series.
  ///
  /// Throws [ArgumentError] on an empty list, on decreasing timestamps, on
  /// an unregistered [version], or on a field table without `timestamp` and
  /// `depth`. These are caller bugs, not data faults.
  EncodedProfileSeries encode(
    List<ProfileSample> samples, {
    int version = ProfileSeriesCodec.version,
  }) {
    final table = fieldTables[version];
    if (table == null) {
      throw ArgumentError.value(version, 'version', 'no field table');
    }
    _requireTimestampAndDepth(table);
    final summary = ProfileSeriesSummary.of(samples);
    for (var i = 1; i < samples.length; i++) {
      if (samples[i].timestamp < samples[i - 1].timestamp) {
        throw ArgumentError.value(
          samples,
          'samples',
          'timestamps must be non-decreasing (sample $i)',
        );
      }
    }

    final writer = ByteWriter()
      ..writeByte(version)
      ..writeVarUint(samples.length);
    for (final field in table) {
      final column = [
        for (final sample in samples) _fieldOf(sample, field.name),
      ];
      _writeColumn(writer, field.kind, column);
    }
    return EncodedProfileSeries(
      bytes: Uint8List.fromList(_zlib.encode(writer.takeBytes())),
      codecVersion: version,
      summary: summary,
    );
  }

  /// Decodes a blob written by [encode] under any registered version.
  ///
  /// Throws [ProfileSeriesCodecException] on anything malformed: not a zlib
  /// stream, an unknown version, a truncated block, trailing bytes, or a
  /// sample without timestamp or depth.
  List<ProfileSample> decode(Uint8List bytes) {
    final Uint8List body;
    try {
      body = Uint8List.fromList(_zlib.decode(bytes));
    } catch (e) {
      throw ProfileSeriesCodecException('not a zlib stream: $e');
    }
    if (body.isEmpty) {
      throw const ProfileSeriesCodecException('empty body');
    }
    final reader = ByteReader(body);
    final blobVersion = reader.readByte();
    final table = fieldTables[blobVersion];
    if (table == null) {
      throw ProfileSeriesCodecException('unknown codec version $blobVersion');
    }
    final count = reader.readVarUint();
    // Every sample carries at least a one-byte timestamp delta, so a count
    // the remaining payload cannot hold is corruption, not a large series.
    // Guarding here keeps a bogus count from sizing 28 column lists.
    if (count > reader.remaining) {
      throw ProfileSeriesCodecException(
        'sample count $count exceeds the ${reader.remaining} remaining '
        'byte(s)',
      );
    }
    final columns = <String, List<Object?>>{};
    for (final field in table) {
      columns[field.name] = _readColumn(reader, field.kind, count);
    }
    if (!reader.isAtEnd) {
      throw ProfileSeriesCodecException(
        '${reader.remaining} trailing byte(s) after the last block',
      );
    }
    return _samplesFrom(columns, count);
  }

  static void _requireTimestampAndDepth(List<ProfileField> table) {
    final names = {for (final field in table) field.name};
    if (!names.contains('timestamp') || !names.contains('depth')) {
      throw ArgumentError.value(
        table,
        'fieldTables',
        'every field table must carry timestamp and depth',
      );
    }
  }

  static Object? _fieldOf(ProfileSample s, String name) => switch (name) {
    'timestamp' => s.timestamp,
    'depth' => s.depth,
    'pressure' => s.pressure,
    'temperature' => s.temperature,
    'heart_rate' => s.heartRate,
    'ascent_rate' => s.ascentRate,
    'ceiling' => s.ceiling,
    'ndl' => s.ndl,
    'setpoint' => s.setpoint,
    'pp_o2' => s.ppO2,
    'o2_sensor1' => s.o2Sensor1,
    'o2_sensor2' => s.o2Sensor2,
    'o2_sensor3' => s.o2Sensor3,
    'o2_sensor4' => s.o2Sensor4,
    'o2_sensor5' => s.o2Sensor5,
    'o2_sensor6' => s.o2Sensor6,
    'cns' => s.cns,
    'tts' => s.tts,
    'rbt' => s.rbt,
    'deco_type' => s.decoType,
    'heart_rate_source' => s.heartRateSource,
    'heading' => s.heading,
    'o2_sensor_mv1' => s.o2SensorMv1,
    'o2_sensor_mv2' => s.o2SensorMv2,
    'o2_sensor_mv3' => s.o2SensorMv3,
    'o2_sensor_mv4' => s.o2SensorMv4,
    'o2_sensor_mv5' => s.o2SensorMv5,
    'o2_sensor_mv6' => s.o2SensorMv6,
    _ => throw ArgumentError.value(name, 'name', 'not a profile sample field'),
  };

  static void _writeColumn(
    ByteWriter writer,
    ProfileFieldKind kind,
    List<Object?> column,
  ) {
    switch (kind) {
      case ProfileFieldKind.deltaInt:
        var previous = 0;
        writer.writeColumn<int>(column.cast<int?>(), (value) {
          writer.writeVarInt(value - previous);
          previous = value;
        });
      case ProfileFieldKind.float64:
        writer.writeColumn<double>(column.cast<double?>(), writer.writeFloat64);
      case ProfileFieldKind.runLengthString:
        _writeStringColumn(writer, column.cast<String?>());
    }
  }

  static List<Object?> _readColumn(
    ByteReader reader,
    ProfileFieldKind kind,
    int count,
  ) {
    switch (kind) {
      case ProfileFieldKind.deltaInt:
        var previous = 0;
        return reader.readColumn<int>(count, () {
          previous += reader.readVarInt();
          return previous;
        });
      case ProfileFieldKind.float64:
        return reader.readColumn<double>(count, reader.readFloat64);
      case ProfileFieldKind.runLengthString:
        return _readStringColumn(reader, count);
    }
  }

  static void _writeStringColumn(ByteWriter writer, List<String?> values) {
    if (!writer.writePresence(values)) return;
    final runs = <(String, int)>[];
    for (final value in values) {
      if (value == null) continue;
      if (runs.isNotEmpty && runs.last.$1 == value) {
        runs[runs.length - 1] = (value, runs.last.$2 + 1);
      } else {
        runs.add((value, 1));
      }
    }
    writer.writeVarUint(runs.length);
    for (final (value, length) in runs) {
      final encoded = utf8.encode(value);
      writer
        ..writeVarUint(length)
        ..writeVarUint(encoded.length)
        ..writeBytes(encoded);
    }
  }

  static List<String?> _readStringColumn(ByteReader reader, int count) {
    final present = reader.readPresence(count);
    var presentCount = 0;
    for (final isPresent in present) {
      if (isPresent) presentCount++;
    }
    if (presentCount == 0) return List<String?>.filled(count, null);
    final runCount = reader.readVarUint();
    final values = <String>[];
    for (var run = 0; run < runCount; run++) {
      final length = reader.readVarUint();
      if (values.length + length > presentCount) {
        throw ProfileSeriesCodecException(
          'string run $run of length $length overruns the $presentCount '
          'present values',
        );
      }
      final byteLength = reader.readVarUint();
      final String value;
      try {
        value = utf8.decode(reader.readBytes(byteLength));
      } on FormatException catch (e) {
        throw ProfileSeriesCodecException(
          'invalid UTF-8 in string run $run: ${e.message}',
        );
      }
      for (var i = 0; i < length; i++) {
        values.add(value);
      }
    }
    if (values.length != presentCount) {
      throw ProfileSeriesCodecException(
        'string runs cover ${values.length} of $presentCount present values',
      );
    }
    var next = 0;
    return [for (final isPresent in present) isPresent ? values[next++] : null];
  }

  static List<ProfileSample> _samplesFrom(
    Map<String, List<Object?>> columns,
    int count,
  ) {
    List<T?> column<T>(String name) {
      final values = columns[name];
      if (values == null) return List<T?>.filled(count, null);
      return values.cast<T?>();
    }

    final timestamps = column<int>('timestamp');
    final depths = column<double>('depth');
    final pressures = column<double>('pressure');
    final temperatures = column<double>('temperature');
    final heartRates = column<int>('heart_rate');
    final ascentRates = column<double>('ascent_rate');
    final ceilings = column<double>('ceiling');
    final ndls = column<int>('ndl');
    final setpoints = column<double>('setpoint');
    final ppO2s = column<double>('pp_o2');
    final o2Sensor1s = column<double>('o2_sensor1');
    final o2Sensor2s = column<double>('o2_sensor2');
    final o2Sensor3s = column<double>('o2_sensor3');
    final o2Sensor4s = column<double>('o2_sensor4');
    final o2Sensor5s = column<double>('o2_sensor5');
    final o2Sensor6s = column<double>('o2_sensor6');
    final cnss = column<double>('cns');
    final ttss = column<int>('tts');
    final rbts = column<int>('rbt');
    final decoTypes = column<int>('deco_type');
    final heartRateSources = column<String>('heart_rate_source');
    final headings = column<double>('heading');
    final mv1s = column<int>('o2_sensor_mv1');
    final mv2s = column<int>('o2_sensor_mv2');
    final mv3s = column<int>('o2_sensor_mv3');
    final mv4s = column<int>('o2_sensor_mv4');
    final mv5s = column<int>('o2_sensor_mv5');
    final mv6s = column<int>('o2_sensor_mv6');

    return [
      for (var i = 0; i < count; i++)
        ProfileSample(
          timestamp:
              timestamps[i] ??
              (throw ProfileSeriesCodecException('sample $i has no timestamp')),
          depth:
              depths[i] ??
              (throw ProfileSeriesCodecException('sample $i has no depth')),
          pressure: pressures[i],
          temperature: temperatures[i],
          heartRate: heartRates[i],
          ascentRate: ascentRates[i],
          ceiling: ceilings[i],
          ndl: ndls[i],
          setpoint: setpoints[i],
          ppO2: ppO2s[i],
          o2Sensor1: o2Sensor1s[i],
          o2Sensor2: o2Sensor2s[i],
          o2Sensor3: o2Sensor3s[i],
          o2Sensor4: o2Sensor4s[i],
          o2Sensor5: o2Sensor5s[i],
          o2Sensor6: o2Sensor6s[i],
          cns: cnss[i],
          tts: ttss[i],
          rbt: rbts[i],
          decoType: decoTypes[i],
          heartRateSource: heartRateSources[i],
          heading: headings[i],
          o2SensorMv1: mv1s[i],
          o2SensorMv2: mv2s[i],
          o2SensorMv3: mv3s[i],
          o2SensorMv4: mv4s[i],
          o2SensorMv5: mv5s[i],
          o2SensorMv6: mv6s[i],
        ),
    ];
  }
}
