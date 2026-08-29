/// Row-decoding helpers for [profileSampleOf], split out of
/// `profile_series_pack.dart` to keep that file under the project's line
/// limit. Same imports discipline as the rest of `lib/core/database`: no
/// Flutter, only what a headless isolate can run.
library;

import 'package:submersion/features/dive_log/domain/codecs/profile_sample.dart';

/// Reads a legacy `dive_profiles` row by column name. Absent columns (an
/// older fixture or a partially migrated table) read as null. Returns null
/// when the row has no timestamp or depth: a restored or hand-repaired
/// legacy table can hold such rows and they cannot become a sample.
ProfileSample? profileSampleOf(Map<String, Object?> data) {
  final timestamp = data['timestamp'] as num?;
  final depth = data['depth'] as num?;
  if (timestamp == null || depth == null) return null;
  return ProfileSample(
    timestamp: timestamp.toInt(),
    depth: depth.toDouble(),
    pressure: realOf(data['pressure']),
    temperature: realOf(data['temperature']),
    heartRate: intOf(data['heart_rate']),
    ascentRate: realOf(data['ascent_rate']),
    ceiling: realOf(data['ceiling']),
    ndl: intOf(data['ndl']),
    setpoint: realOf(data['setpoint']),
    ppO2: realOf(data['pp_o2']),
    o2Sensor1: realOf(data['o2_sensor1']),
    o2Sensor2: realOf(data['o2_sensor2']),
    o2Sensor3: realOf(data['o2_sensor3']),
    o2Sensor4: realOf(data['o2_sensor4']),
    o2Sensor5: realOf(data['o2_sensor5']),
    o2Sensor6: realOf(data['o2_sensor6']),
    cns: realOf(data['cns']),
    tts: intOf(data['tts']),
    rbt: intOf(data['rbt']),
    decoType: intOf(data['deco_type']),
    heartRateSource: data['heart_rate_source'] as String?,
    heading: realOf(data['heading']),
    o2SensorMv1: intOf(data['o2_sensor_mv1']),
    o2SensorMv2: intOf(data['o2_sensor_mv2']),
    o2SensorMv3: intOf(data['o2_sensor_mv3']),
    o2SensorMv4: intOf(data['o2_sensor_mv4']),
    o2SensorMv5: intOf(data['o2_sensor_mv5']),
    o2SensorMv6: intOf(data['o2_sensor_mv6']),
  );
}

double? realOf(Object? value) => (value as num?)?.toDouble();

int? intOf(Object? value) => (value as num?)?.toInt();
