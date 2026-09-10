/// One profile sample decoded from MacDive's `ZDIVE.ZSAMPLES` column.
///
/// Values are exactly as MacDive stored them. Depth and temperature are SI
/// (metres, Celsius) like every other Core Data column of that kind, while
/// the two tank pressures follow the diver's display unit at the time the
/// dive was stored, the same convention as `ZTANKANDGAS.ZAIRSTART`. The
/// caller converts those with `MacDiveUnitConverter`, which already knows the
/// library's unit system; the decoder itself is unit-agnostic.
///
/// A null field means the dive's options word did not include that channel,
/// not that the value was zero.
class MacDiveSqliteSample {
  const MacDiveSqliteSample({
    required this.time,
    required this.depthMeters,
    this.pressure,
    this.pressure2,
    this.heartRate,
    this.ndtMinutes,
    this.ppO2,
    this.temperatureCelsius,
    this.nextStopDepthMeters,
    this.ttsMinutes,
  });

  /// Elapsed time since the start of the dive.
  final Duration time;

  final double depthMeters;

  /// Primary tank pressure in the diver's display unit (psi or bar).
  final double? pressure;

  /// Second transmitter's pressure, same unit as [pressure].
  final double? pressure2;

  final int? heartRate;

  /// No-decompression time remaining, in minutes, as MacDive's own XML export
  /// writes it.
  final int? ndtMinutes;

  /// Partial pressure of oxygen in bar.
  final double? ppO2;

  final double? temperatureCelsius;

  /// Depth of the next required decompression stop; zero when there is none.
  final double? nextStopDepthMeters;

  /// Time to surface in minutes.
  final int? ttsMinutes;
}
