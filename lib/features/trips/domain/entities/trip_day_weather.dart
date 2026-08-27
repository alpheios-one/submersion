import 'package:equatable/equatable.dart';
import 'package:uuid/uuid.dart';

import 'package:submersion/core/constants/enums.dart';
import 'package:submersion/features/trips/domain/entities/trip_story_day.dart';

/// Fixed namespace for deterministic trip-day-weather ids (UUIDv5).
/// Never change: the ids already stored depend on it.
const String kTripDayWeatherNamespace = '3f1c8a52-9e47-4d6b-8b3a-16c9d0f27e45';

/// Deterministic row id for one trip day.
///
/// The day is the identity, so the id must be derived from it rather than
/// minted per device. Two devices that both fetch the same day would
/// otherwise insert two rows, and the unique (trip_id, date) index turns the
/// second one into an inbound-sync failure rather than a merge: the
/// serializer upserts by primary key, so a differing id misses the conflict
/// target entirely and hits the index instead. That throws inside the merge
/// transaction and aborts the whole sync pull.
///
/// [dayMillis] must already be normalized to local midnight; the repository
/// does that before calling here.
String tripDayWeatherRowId({required String tripId, required int dayMillis}) =>
    const Uuid().v5(kTripDayWeatherNamespace, '$tripId|$dayMillis');

/// Stored historical weather for one trip day.
///
/// Written only for days whose dives supply no weather of their own; a day
/// with dive-logged weather renders that instead, because it is what the
/// diver actually recorded.
///
/// Metric throughout (celsius, m/s, bar). Conversion to the diver's units
/// happens at display time.
class TripDayWeather extends Equatable {
  final String id;
  final String tripId;

  /// Local midnight for the day this describes.
  final DateTime date;

  /// The coordinates the lookup used.
  final double latitude;
  final double longitude;

  final double? airTemp; // celsius
  final CloudCover? cloudCover;
  final Precipitation? precipitation;
  final double? windSpeed; // m/s
  final CurrentDirection? windDirection;
  final double? humidity; // 0-100
  final double? surfacePressure; // bar

  /// Raw WMO weather code (0 clear, 61 rain, 95 thunderstorm, ...), kept so
  /// the description can be rendered in the diver's locale at display time.
  final int? weatherCode;

  final WeatherSource weatherSource;
  final DateTime fetchedAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  const TripDayWeather({
    required this.id,
    required this.tripId,
    required this.date,
    required this.latitude,
    required this.longitude,
    this.airTemp,
    this.cloudCover,
    this.precipitation,
    this.windSpeed,
    this.windDirection,
    this.humidity,
    this.surfacePressure,
    this.weatherCode,
    this.weatherSource = WeatherSource.openMeteo,
    required this.fetchedAt,
    required this.createdAt,
    required this.updatedAt,
  });

  /// True when the day header's badge would actually show something.
  ///
  /// Wind, humidity, and pressure are stored but never drawn, so a row
  /// carrying only those renders as nothing and would suppress the retry that
  /// a later archive update would satisfy.
  ///
  /// Delegates to [TripStoryDayWeather.isRenderable] so the rule that decides
  /// what is worth storing is the same one that decides what the header can
  /// draw, and the same one the backfill uses to judge a day's dive weather.
  bool get hasRenderableWeather => toStoryWeather().isRenderable;

  /// The compact view model the day header consumes.
  TripStoryDayWeather toStoryWeather() => TripStoryDayWeather(
    airTemp: airTemp,
    cloudCover: cloudCover,
    precipitation: precipitation,
  );

  TripDayWeather copyWith({
    String? id,
    String? tripId,
    DateTime? date,
    double? latitude,
    double? longitude,
    Object? airTemp = _undefined,
    Object? cloudCover = _undefined,
    Object? precipitation = _undefined,
    Object? windSpeed = _undefined,
    Object? windDirection = _undefined,
    Object? humidity = _undefined,
    Object? surfacePressure = _undefined,
    Object? weatherCode = _undefined,
    WeatherSource? weatherSource,
    DateTime? fetchedAt,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return TripDayWeather(
      id: id ?? this.id,
      tripId: tripId ?? this.tripId,
      date: date ?? this.date,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      airTemp: airTemp == _undefined ? this.airTemp : airTemp as double?,
      cloudCover: cloudCover == _undefined
          ? this.cloudCover
          : cloudCover as CloudCover?,
      precipitation: precipitation == _undefined
          ? this.precipitation
          : precipitation as Precipitation?,
      windSpeed: windSpeed == _undefined
          ? this.windSpeed
          : windSpeed as double?,
      windDirection: windDirection == _undefined
          ? this.windDirection
          : windDirection as CurrentDirection?,
      humidity: humidity == _undefined ? this.humidity : humidity as double?,
      surfacePressure: surfacePressure == _undefined
          ? this.surfacePressure
          : surfacePressure as double?,
      weatherCode: weatherCode == _undefined
          ? this.weatherCode
          : weatherCode as int?,
      weatherSource: weatherSource ?? this.weatherSource,
      fetchedAt: fetchedAt ?? this.fetchedAt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  List<Object?> get props => [
    id,
    tripId,
    date,
    latitude,
    longitude,
    airTemp,
    cloudCover,
    precipitation,
    windSpeed,
    windDirection,
    humidity,
    surfacePressure,
    weatherCode,
    weatherSource,
    fetchedAt,
    createdAt,
    updatedAt,
  ];
}

// Sentinel value for distinguishing null from undefined in copyWith
const _undefined = Object();
