import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import 'package:submersion/core/data/repositories/sync_repository.dart';
import 'package:submersion/core/database/database.dart';
import 'package:submersion/core/services/database_service.dart';
import 'package:submersion/core/services/logger_service.dart';
import 'package:submersion/core/services/sync/sync_event_bus.dart';
import 'package:submersion/features/dive_computer/domain/entities/transmitter_entity.dart';

/// CRUD access to the transmitter (air-integration channel) registry, which
/// maps a dive computer's channel index to a cylinder role/template so
/// downloads can assign size, gas and role deterministically (issue #1365).
class TransmitterRepository {
  AppDatabase get _db => DatabaseService.instance.database;
  final SyncRepository _syncRepository = SyncRepository();
  final _uuid = const Uuid();
  final _log = LoggerService.forClass(TransmitterRepository);

  /// Emits whenever the `transmitters` table changes so list providers can
  /// refresh after a sync or any other write.
  Stream<void> watchTransmittersChanges() =>
      _db.tableUpdates(TableUpdateQuery.onTable(_db.transmitters));

  /// All registry entries for [diveComputerId], ordered by channel index.
  Future<List<TransmitterEntity>> getForComputer(String diveComputerId) async {
    try {
      final rows =
          await (_db.select(_db.transmitters)
                ..where((t) => t.diveComputerId.equals(diveComputerId))
                ..orderBy([(t) => OrderingTerm.asc(t.channelIndex)]))
              .get();
      return rows.map(_mapRowToEntity).toList();
    } catch (e, stackTrace) {
      _log.error(
        'Failed to get transmitters for computer: $diveComputerId',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<TransmitterEntity?> getById(String id) async {
    try {
      final row = await (_db.select(
        _db.transmitters,
      )..where((t) => t.id.equals(id))).getSingleOrNull();
      return row == null ? null : _mapRowToEntity(row);
    } catch (e, stackTrace) {
      _log.error(
        'Failed to get transmitter by id: $id',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// The registry entry for (diveComputerId, channelIndex), or null when the
  /// channel has never been assigned.
  Future<TransmitterEntity?> getForChannel(
    String diveComputerId,
    int channelIndex,
  ) async {
    try {
      final row =
          await (_db.select(_db.transmitters)..where(
                (t) =>
                    t.diveComputerId.equals(diveComputerId) &
                    t.channelIndex.equals(channelIndex),
              ))
              .getSingleOrNull();
      return row == null ? null : _mapRowToEntity(row);
    } catch (e, stackTrace) {
      _log.error(
        'Failed to get transmitter for computer $diveComputerId '
        'channel $channelIndex',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// Create or update the registry entry for (entry.diveComputerId,
  /// entry.channelIndex). [entry.id] is regenerated on create.
  Future<TransmitterEntity> upsert(TransmitterEntity entry) async {
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final existing = await getForChannel(
        entry.diveComputerId,
        entry.channelIndex,
      );
      final id = existing?.id ?? (entry.id.isEmpty ? _uuid.v4() : entry.id);

      await _db
          .into(_db.transmitters)
          .insertOnConflictUpdate(
            TransmittersCompanion(
              id: Value(id),
              diveComputerId: Value(entry.diveComputerId),
              channelIndex: Value(entry.channelIndex),
              label: Value(entry.label),
              transmitterSerial: Value(entry.transmitterSerial),
              equipmentId: Value(entry.equipmentId),
              tankRole: Value(entry.tankRole),
              tankPresetId: Value(entry.tankPresetId),
              createdAt: Value(
                existing?.createdAt.millisecondsSinceEpoch ?? now,
              ),
              updatedAt: Value(now),
            ),
          );
      await _syncRepository.markRecordPending(
        entityType: 'transmitters',
        recordId: id,
        localUpdatedAt: now,
      );
      SyncEventBus.notifyLocalChange();

      return entry.copyWith(
        id: id,
        createdAt:
            existing?.createdAt ?? DateTime.fromMillisecondsSinceEpoch(now),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(now),
      );
    } catch (e, stackTrace) {
      _log.error(
        'Failed to upsert transmitter for computer ${entry.diveComputerId} '
        'channel ${entry.channelIndex}',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<void> delete(String id) async {
    try {
      await (_db.delete(_db.transmitters)..where((t) => t.id.equals(id))).go();
      await _syncRepository.logDeletion(
        entityType: 'transmitters',
        recordId: id,
      );
      SyncEventBus.notifyLocalChange();
    } catch (e, stackTrace) {
      _log.error(
        'Failed to delete transmitter: $id',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  TransmitterEntity _mapRowToEntity(Transmitter row) {
    return TransmitterEntity(
      id: row.id,
      diveComputerId: row.diveComputerId,
      channelIndex: row.channelIndex,
      label: row.label,
      transmitterSerial: row.transmitterSerial,
      equipmentId: row.equipmentId,
      tankRole: row.tankRole,
      tankPresetId: row.tankPresetId,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row.updatedAt),
    );
  }
}
