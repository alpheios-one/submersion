import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/features/dive_log/domain/codecs/profile_field_table.dart';
import 'package:submersion/features/dive_log/domain/codecs/profile_series_codec.dart';
import 'package:submersion/features/dive_log/domain/codecs/tank_pressure_series_codec.dart';

/// The v1 field table, frozen. It used to be cross-checked against the
/// `dive_profiles` Drift columns; v183 dropped that table, and a frozen list
/// is what the invariant actually needs: every blob already on disk (and on
/// every peer) was written against this exact order, so an entry may never be
/// reordered, renamed, or removed. A new sample field is appended under a NEW
/// codec version, never here.
const frozenFieldTableV1 = <(String, ProfileFieldKind)>[
  ('timestamp', ProfileFieldKind.deltaInt),
  ('depth', ProfileFieldKind.float64),
  ('pressure', ProfileFieldKind.float64),
  ('temperature', ProfileFieldKind.float64),
  ('heart_rate', ProfileFieldKind.deltaInt),
  ('ascent_rate', ProfileFieldKind.float64),
  ('ceiling', ProfileFieldKind.float64),
  ('ndl', ProfileFieldKind.deltaInt),
  ('setpoint', ProfileFieldKind.float64),
  ('pp_o2', ProfileFieldKind.float64),
  ('o2_sensor1', ProfileFieldKind.float64),
  ('o2_sensor2', ProfileFieldKind.float64),
  ('o2_sensor3', ProfileFieldKind.float64),
  ('o2_sensor4', ProfileFieldKind.float64),
  ('o2_sensor5', ProfileFieldKind.float64),
  ('o2_sensor6', ProfileFieldKind.float64),
  ('cns', ProfileFieldKind.float64),
  ('tts', ProfileFieldKind.deltaInt),
  ('rbt', ProfileFieldKind.deltaInt),
  ('deco_type', ProfileFieldKind.deltaInt),
  ('heart_rate_source', ProfileFieldKind.runLengthString),
  ('heading', ProfileFieldKind.float64),
  ('o2_sensor_mv1', ProfileFieldKind.deltaInt),
  ('o2_sensor_mv2', ProfileFieldKind.deltaInt),
  ('o2_sensor_mv3', ProfileFieldKind.deltaInt),
  ('o2_sensor_mv4', ProfileFieldKind.deltaInt),
  ('o2_sensor_mv5', ProfileFieldKind.deltaInt),
  ('o2_sensor_mv6', ProfileFieldKind.deltaInt),
];

void main() {
  test('codec v1 carries exactly the frozen field table, in order', () {
    expect(
      [for (final f in ProfileSeriesCodec.fieldTableV1) (f.name, f.kind)],
      frozenFieldTableV1,
      reason:
          'fieldTableV1 changed. Every blob already written (here and on '
          'every peer) decodes against this exact order. Append the new '
          'field under a NEW version in ProfileSeriesCodec; never edit '
          'fieldTableV1.',
    );
  });

  test('every sample field is representable by the codec', () {
    // The whole ProfileSample surface, minus the identity the series row
    // carries: if a sample field ever gains a member with no field-table
    // entry, it would be silently dropped on encode.
    const sampleFields = {
      'timestamp',
      'depth',
      'pressure',
      'temperature',
      'heart_rate',
      'ascent_rate',
      'ceiling',
      'ndl',
      'setpoint',
      'pp_o2',
      'o2_sensor1',
      'o2_sensor2',
      'o2_sensor3',
      'o2_sensor4',
      'o2_sensor5',
      'o2_sensor6',
      'cns',
      'tts',
      'rbt',
      'deco_type',
      'heart_rate_source',
      'heading',
      'o2_sensor_mv1',
      'o2_sensor_mv2',
      'o2_sensor_mv3',
      'o2_sensor_mv4',
      'o2_sensor_mv5',
      'o2_sensor_mv6',
    };
    expect({
      for (final f in ProfileSeriesCodec.fieldTableV1) f.name,
    }, sampleFields);
  });

  test('the tank codec packs exactly timestamp and pressure', () {
    const sample = TankPressureSample(timestamp: 30, pressure: 180.0);
    expect(sample.timestamp, 30);
    expect(sample.pressure, 180.0);
    const codec = TankPressureSeriesCodec();
    final decoded = codec.decode(codec.encode(const [sample]).bytes);
    expect(decoded.single.timestamp, 30);
    expect(decoded.single.pressure, 180.0);
  });
}
