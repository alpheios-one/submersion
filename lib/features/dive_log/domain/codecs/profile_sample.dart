import 'package:equatable/equatable.dart';
import 'package:submersion/features/dive_log/domain/entities/dive.dart';

/// One profile sample exactly as the `dive_profiles` table stores it, minus
/// the identity columns (`id`, `dive_id`, `computer_id`, `source_id`,
/// `is_primary`) that live on the series row.
///
/// This is the codec's input and output type. It differs from
/// [DiveProfilePoint] in one field: the legacy per-sample [pressure]
/// column, which the v59 migration moved to tank pressure profiles but
/// which older rows still populate. The codec is lossless over the stored
/// row, so the field rides along; [toPoint] drops it, as every read path
/// does today.
class ProfileSample extends Equatable {
  const ProfileSample({
    required this.timestamp,
    required this.depth,
    this.pressure,
    this.temperature,
    this.heartRate,
    this.ascentRate,
    this.ceiling,
    this.ndl,
    this.setpoint,
    this.ppO2,
    this.o2Sensor1,
    this.o2Sensor2,
    this.o2Sensor3,
    this.o2Sensor4,
    this.o2Sensor5,
    this.o2Sensor6,
    this.cns,
    this.tts,
    this.rbt,
    this.decoType,
    this.heartRateSource,
    this.heading,
    this.o2SensorMv1,
    this.o2SensorMv2,
    this.o2SensorMv3,
    this.o2SensorMv4,
    this.o2SensorMv5,
    this.o2SensorMv6,
  });

  factory ProfileSample.fromPoint(DiveProfilePoint point, {double? pressure}) {
    return ProfileSample(
      timestamp: point.timestamp,
      depth: point.depth,
      pressure: pressure,
      temperature: point.temperature,
      heartRate: point.heartRate,
      ascentRate: point.ascentRate,
      ceiling: point.ceiling,
      ndl: point.ndl,
      setpoint: point.setpoint,
      ppO2: point.ppO2,
      o2Sensor1: point.o2Sensor1,
      o2Sensor2: point.o2Sensor2,
      o2Sensor3: point.o2Sensor3,
      o2Sensor4: point.o2Sensor4,
      o2Sensor5: point.o2Sensor5,
      o2Sensor6: point.o2Sensor6,
      cns: point.cns,
      tts: point.tts,
      rbt: point.rbt,
      decoType: point.decoType,
      heartRateSource: point.heartRateSource,
      heading: point.heading,
      o2SensorMv1: point.o2SensorMv1,
      o2SensorMv2: point.o2SensorMv2,
      o2SensorMv3: point.o2SensorMv3,
      o2SensorMv4: point.o2SensorMv4,
      o2SensorMv5: point.o2SensorMv5,
      o2SensorMv6: point.o2SensorMv6,
    );
  }

  /// Seconds from dive start.
  final int timestamp;

  /// Metres.
  final double depth;

  /// Legacy per-sample pressure in bar; null on every row written after the
  /// v59 migration.
  final double? pressure;
  final double? temperature;
  final int? heartRate;
  final double? ascentRate;
  final double? ceiling;
  final int? ndl;
  final double? setpoint;
  final double? ppO2;
  final double? o2Sensor1;
  final double? o2Sensor2;
  final double? o2Sensor3;
  final double? o2Sensor4;
  final double? o2Sensor5;
  final double? o2Sensor6;
  final double? cns;
  final int? tts;
  final int? rbt;
  final int? decoType;
  final String? heartRateSource;
  final double? heading;
  final int? o2SensorMv1;
  final int? o2SensorMv2;
  final int? o2SensorMv3;
  final int? o2SensorMv4;
  final int? o2SensorMv5;
  final int? o2SensorMv6;

  /// The domain point. Drops [pressure], which [DiveProfilePoint] does not
  /// carry.
  DiveProfilePoint toPoint() {
    return DiveProfilePoint(
      timestamp: timestamp,
      depth: depth,
      temperature: temperature,
      heartRate: heartRate,
      heading: heading,
      setpoint: setpoint,
      ppO2: ppO2,
      o2Sensor1: o2Sensor1,
      o2Sensor2: o2Sensor2,
      o2Sensor3: o2Sensor3,
      o2Sensor4: o2Sensor4,
      o2Sensor5: o2Sensor5,
      o2Sensor6: o2Sensor6,
      o2SensorMv1: o2SensorMv1,
      o2SensorMv2: o2SensorMv2,
      o2SensorMv3: o2SensorMv3,
      o2SensorMv4: o2SensorMv4,
      o2SensorMv5: o2SensorMv5,
      o2SensorMv6: o2SensorMv6,
      heartRateSource: heartRateSource,
      cns: cns,
      ndl: ndl,
      ceiling: ceiling,
      ascentRate: ascentRate,
      rbt: rbt,
      decoType: decoType,
      tts: tts,
    );
  }

  @override
  List<Object?> get props => [
    timestamp,
    depth,
    pressure,
    temperature,
    heartRate,
    ascentRate,
    ceiling,
    ndl,
    setpoint,
    ppO2,
    o2Sensor1,
    o2Sensor2,
    o2Sensor3,
    o2Sensor4,
    o2Sensor5,
    o2Sensor6,
    cns,
    tts,
    rbt,
    decoType,
    heartRateSource,
    heading,
    o2SensorMv1,
    o2SensorMv2,
    o2SensorMv3,
    o2SensorMv4,
    o2SensorMv5,
    o2SensorMv6,
  ];
}
