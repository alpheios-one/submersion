import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/constants/enums.dart';
import 'package:submersion/features/trips/domain/entities/trip_day_weather.dart';

void main() {
  TripDayWeather weather({
    double? airTemp,
    CloudCover? cloudCover,
    Precipitation? precipitation,
    double? windSpeed,
    double? humidity,
  }) {
    final now = DateTime(2026, 3, 9);
    return TripDayWeather(
      id: 'w1',
      tripId: 'trip-1',
      date: DateTime(2026, 3, 8),
      latitude: 12.16,
      longitude: -68.28,
      airTemp: airTemp,
      cloudCover: cloudCover,
      precipitation: precipitation,
      windSpeed: windSpeed,
      humidity: humidity,
      fetchedAt: now,
      createdAt: now,
      updatedAt: now,
    );
  }

  group('hasRenderableWeather', () {
    test('air temperature alone counts', () {
      expect(weather(airTemp: 24).hasRenderableWeather, isTrue);
    });

    test('cloud cover alone counts', () {
      expect(
        weather(cloudCover: CloudCover.overcast).hasRenderableWeather,
        isTrue,
      );
    });

    test('active precipitation alone counts', () {
      expect(
        weather(precipitation: Precipitation.rain).hasRenderableWeather,
        isTrue,
      );
    });

    test('precipitation none alone does NOT count', () {
      // WeatherMapper.mapPrecipitation never returns null: a missing reading
      // becomes Precipitation.none, so `none` is not evidence that the fetch
      // resolved anything. weatherIconFor gives it no glyph either.
      expect(
        weather(precipitation: Precipitation.none).hasRenderableWeather,
        isFalse,
      );
    });

    test('wind and humidity alone do NOT count', () {
      // Stored, but never drawn in the day header badge.
      expect(
        weather(
          windSpeed: 6.5,
          humidity: 70,
          precipitation: Precipitation.none,
        ).hasRenderableWeather,
        isFalse,
      );
    });

    test('an empty result does not count', () {
      expect(weather().hasRenderableWeather, isFalse);
    });
  });

  group('toStoryWeather', () {
    test('carries only the three fields the header renders', () {
      final story = weather(
        airTemp: 24,
        cloudCover: CloudCover.clear,
        precipitation: Precipitation.none,
        windSpeed: 6.5,
        humidity: 70,
      ).toStoryWeather();

      expect(story.airTemp, 24);
      expect(story.cloudCover, CloudCover.clear);
      expect(story.precipitation, Precipitation.none);
    });
  });

  group('copyWith', () {
    test('clears a nullable field when passed null explicitly', () {
      final cleared = weather(airTemp: 24).copyWith(airTemp: null);

      expect(cleared.airTemp, isNull);
    });

    test('leaves an untouched field alone', () {
      final same = weather(airTemp: 24).copyWith(latitude: 0);

      expect(same.airTemp, 24);
      expect(same.latitude, 0);
    });
  });
}
