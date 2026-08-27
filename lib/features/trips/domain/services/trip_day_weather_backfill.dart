import 'package:equatable/equatable.dart';

import 'package:submersion/features/trips/domain/entities/trip_day_weather.dart';
import 'package:submersion/features/trips/domain/entities/trip_story.dart';
import 'package:submersion/features/trips/domain/entities/trip_story_day.dart';

/// One trip day that needs a weather lookup, with the coordinates to look it
/// up at.
class TripDayWeatherTarget extends Equatable {
  /// Local midnight for the day.
  final DateTime date;
  final double latitude;
  final double longitude;

  const TripDayWeatherTarget({
    required this.date,
    required this.latitude,
    required this.longitude,
  });

  /// The hour to sample. Noon local reads as "the day's weather" far better
  /// than the archive's default midnight boundary, which straddles two days.
  DateTime get localNoon => DateTime(date.year, date.month, date.day, 12);

  @override
  List<Object?> get props => [date, latitude, longitude];
}

/// Decides which trip days need a weather lookup.
///
/// Pure by design: no database, no network, no clock. Every skip rule is a
/// plain condition over the built story and the rows already stored, which is
/// what makes each one directly testable.
class TripDayWeatherBackfill {
  const TripDayWeatherBackfill._();

  static List<TripDayWeatherTarget> targetsFor({
    required TripStory story,
    required Map<int, TripDayWeather> stored,
  }) {
    final targets = <TripDayWeatherTarget>[];

    for (var index = 0; index < story.days.length; index++) {
      final day = story.days[index];

      // A dive that logged weather is the better source: it is what the diver
      // recorded. Never override it with a fetched summary.
      //
      // Renderability, not mere presence, is the test. A dive whose weather
      // lookup resolved nothing still stores Precipitation.none, because
      // WeatherMapper never returns null precipitation, and that renders as a
      // blank badge. Skipping on presence alone would leave such a day
      // permanently badge-free.
      if (day.weather?.isRenderable ?? false) continue;

      // A historical archive has nothing for a day that has not happened.
      if (day.kind == TripStoryDayKind.future) continue;

      // Normalize to midnight: stored rows are keyed on midnight millis, so a
      // stray time component would never match and the day would refetch on
      // every view.
      final date = DateTime(day.date.year, day.date.month, day.date.day);
      if (stored.containsKey(date.millisecondsSinceEpoch)) continue;

      // nearestPointForDay walks outward from the day, so a dive-free day
      // between two dived days borrows the closer one's coordinates. A trip
      // with no mappable point anywhere has nowhere to ask.
      final point = story.mapGeometry.nearestPointForDay(index);
      if (point == null) continue;

      targets.add(
        TripDayWeatherTarget(
          date: date,
          latitude: point.latitude,
          longitude: point.longitude,
        ),
      );
    }

    return targets;
  }
}
