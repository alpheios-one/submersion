import 'package:drift/drift.dart';

import 'package:submersion/core/constants/enums.dart';
import 'package:submersion/core/data/repositories/sync_repository.dart';
import 'package:submersion/core/database/database.dart';
import 'package:submersion/core/services/database_service.dart';
import 'package:submersion/core/services/logger_service.dart';
import 'package:submersion/core/services/sync/sync_event_bus.dart';
import 'package:submersion/features/trips/domain/entities/trip_day_weather.dart'
    as domain;

/// Reads and writes stored per-day trip weather.
///
/// The day is the identity, not the row id: `upsert` replaces any existing
/// row for the same (trip, date), so two devices that both fetch the same day
/// converge on one row rather than accumulating duplicates.
class TripDayWeatherRepository {
  AppDatabase get _db => DatabaseService.instance.database;
  final SyncRepository _syncRepository = SyncRepository();
  final _log = LoggerService.forClass(TripDayWeatherRepository);

  /// Emits whenever `trip_day_weather` changes, so the display provider
  /// refreshes after a backfill write or a sync import.
  Stream<void> watchWeatherChanges() =>
      _db.tableUpdates(TableUpdateQuery.onTable(_db.tripDayWeather));

  /// Stored weather for a trip, keyed by `date.millisecondsSinceEpoch`.
  Future<Map<int, domain.TripDayWeather>> getForTrip(String tripId) async {
    try {
      final rows = await (_db.select(
        _db.tripDayWeather,
      )..where((t) => t.tripId.equals(tripId))).get();
      return {for (final row in rows) row.date: _mapRow(row)};
    } catch (e, stackTrace) {
      _log.error(
        'Failed to read weather for trip: $tripId',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// Insert or replace one day's weather.
  Future<void> upsert(domain.TripDayWeather weather) async {
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final dateMillis = weather.date.millisecondsSinceEpoch;

      // Reuse the stored row's id when the day already has one: a peer may
      // have written its own uuid for this day, and replacing it under a new
      // id would violate the unique index and orphan the peer's sync record.
      final existing =
          await (_db.select(_db.tripDayWeather)..where(
                (t) =>
                    t.tripId.equals(weather.tripId) & t.date.equals(dateMillis),
              ))
              .getSingleOrNull();
      final id = existing?.id ?? weather.id;

      await _db
          .into(_db.tripDayWeather)
          .insertOnConflictUpdate(
            TripDayWeatherCompanion(
              id: Value(id),
              tripId: Value(weather.tripId),
              date: Value(dateMillis),
              latitude: Value(weather.latitude),
              longitude: Value(weather.longitude),
              airTemp: Value(weather.airTemp),
              cloudCover: Value(weather.cloudCover?.name),
              precipitation: Value(weather.precipitation?.name),
              windSpeed: Value(weather.windSpeed),
              windDirection: Value(weather.windDirection?.name),
              humidity: Value(weather.humidity),
              surfacePressure: Value(weather.surfacePressure),
              weatherCode: Value(weather.weatherCode),
              weatherSource: Value(weather.weatherSource.name),
              fetchedAt: Value(weather.fetchedAt.millisecondsSinceEpoch),
              createdAt: Value(
                existing?.createdAt ?? weather.createdAt.millisecondsSinceEpoch,
              ),
              updatedAt: Value(now),
            ),
          );

      await _syncRepository.markRecordPending(
        entityType: 'tripDayWeather',
        recordId: id,
        localUpdatedAt: now,
      );
      SyncEventBus.notifyLocalChange();
    } catch (e, stackTrace) {
      _log.error(
        'Failed to store weather for trip: ${weather.tripId}',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// Delete every stored day for a trip, logging each id for sync.
  Future<void> deleteByTripId(String tripId) async {
    try {
      final existing = await (_db.select(
        _db.tripDayWeather,
      )..where((t) => t.tripId.equals(tripId))).get();
      if (existing.isEmpty) return;

      await (_db.delete(
        _db.tripDayWeather,
      )..where((t) => t.tripId.equals(tripId))).go();

      for (final row in existing) {
        await _syncRepository.logDeletion(
          entityType: 'tripDayWeather',
          recordId: row.id,
        );
      }
      SyncEventBus.notifyLocalChange();

      _log.info('Deleted ${existing.length} weather days for trip: $tripId');
    } catch (e, stackTrace) {
      _log.error(
        'Failed to delete weather for trip: $tripId',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  domain.TripDayWeather _mapRow(TripDayWeatherData row) {
    return domain.TripDayWeather(
      id: row.id,
      tripId: row.tripId,
      date: DateTime.fromMillisecondsSinceEpoch(row.date),
      latitude: row.latitude,
      longitude: row.longitude,
      airTemp: row.airTemp,
      cloudCover: row.cloudCover == null
          ? null
          : CloudCover.values.byName(row.cloudCover!),
      precipitation: row.precipitation == null
          ? null
          : Precipitation.values.byName(row.precipitation!),
      windSpeed: row.windSpeed,
      windDirection: row.windDirection == null
          ? null
          : CurrentDirection.values.byName(row.windDirection!),
      humidity: row.humidity,
      surfacePressure: row.surfacePressure,
      weatherCode: row.weatherCode,
      weatherSource: WeatherSource.values.byName(row.weatherSource),
      fetchedAt: DateTime.fromMillisecondsSinceEpoch(row.fetchedAt),
      createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row.updatedAt),
    );
  }
}
