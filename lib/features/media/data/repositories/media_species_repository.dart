import 'dart:math';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import 'package:submersion/core/data/repositories/sync_repository.dart';
import 'package:submersion/core/database/database.dart';
import 'package:submersion/core/services/database_service.dart';
import 'package:submersion/core/services/sync/sync_event_bus.dart';
import 'package:submersion/features/media/domain/entities/media_item.dart';

/// Species tags on photos: the `media_species` link table.
///
/// A tag sits on a photo that already belongs to a dive or a site; this
/// repository never creates media rows. The table has no `hlc` column, so
/// like `site_species` it syncs as a clockless child: add marks the row
/// pending, remove tombstones it by id, and the incremental export keys off
/// the parent `media.hlc`.
class MediaSpeciesRepository {
  AppDatabase get _db => DatabaseService.instance.database;
  final SyncRepository _syncRepository = SyncRepository();
  static const Uuid _uuid = Uuid();

  /// Bound-variable budget per `isIn` chunk, well under SQLite's 999 limit.
  static const int _chunkSize = 500;

  /// Ticks whenever `media_species` changes, from any writer.
  Stream<void> watchTagChanges() =>
      _db.tableUpdates(TableUpdateQuery.onTable(_db.mediaSpecies));

  Future<List<MediaSpeciesTag>> getTagsForMedia(String mediaId) async {
    final rows =
        await (_db.select(_db.mediaSpecies)
              ..where((t) => t.mediaId.equals(mediaId))
              ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
            .get();
    return rows.map(_tagFromRow).toList();
  }

  /// Tags for many photos in one pass, keyed by media id. Photos without a
  /// tag are absent from the map.
  Future<Map<String, List<MediaSpeciesTag>>> getTagsForMediaIds(
    List<String> mediaIds,
  ) async {
    final result = <String, List<MediaSpeciesTag>>{};
    for (var i = 0; i < mediaIds.length; i += _chunkSize) {
      final chunk = mediaIds.sublist(i, min(i + _chunkSize, mediaIds.length));
      final rows = await (_db.select(
        _db.mediaSpecies,
      )..where((t) => t.mediaId.isIn(chunk))).get();
      for (final row in rows) {
        result.putIfAbsent(row.mediaId, () => []).add(_tagFromRow(row));
      }
    }
    return result;
  }

  /// Tags [mediaId] with [speciesId]. Returns the existing tag when the pair
  /// is already linked: uniqueness lives here, not in a schema constraint.
  Future<MediaSpeciesTag> addTag({
    required String mediaId,
    required String speciesId,
    String? sightingId,
  }) async {
    final existing = await _findTag(mediaId, speciesId);
    if (existing != null) return _tagFromRow(existing);

    final id = _uuid.v4();
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db
        .into(_db.mediaSpecies)
        .insert(
          MediaSpeciesCompanion(
            id: Value(id),
            mediaId: Value(mediaId),
            speciesId: Value(speciesId),
            sightingId: Value(sightingId),
            createdAt: Value(now),
          ),
        );
    await _syncRepository.markRecordPending(
      entityType: 'mediaSpecies',
      recordId: id,
      localUpdatedAt: now,
    );
    SyncEventBus.notifyLocalChange();

    return MediaSpeciesTag(
      id: id,
      mediaId: mediaId,
      speciesId: speciesId,
      sightingId: sightingId,
      createdAt: DateTime.fromMillisecondsSinceEpoch(now),
    );
  }

  /// Removes the tag linking [mediaId] and [speciesId], tombstoning it by
  /// row id so other devices drop the same row. No-op when absent.
  Future<void> removeTag({
    required String mediaId,
    required String speciesId,
  }) async {
    final existing = await _findTag(mediaId, speciesId);
    if (existing == null) return;

    await (_db.delete(
      _db.mediaSpecies,
    )..where((t) => t.id.equals(existing.id))).go();
    await _syncRepository.logDeletion(
      entityType: 'mediaSpecies',
      recordId: existing.id,
    );
    SyncEventBus.notifyLocalChange();
  }

  Future<MediaSpecy?> _findTag(String mediaId, String speciesId) =>
      (_db.select(_db.mediaSpecies)
            ..where(
              (t) => t.mediaId.equals(mediaId) & t.speciesId.equals(speciesId),
            )
            ..limit(1))
          .getSingleOrNull();

  MediaSpeciesTag _tagFromRow(MediaSpecy row) => MediaSpeciesTag(
    id: row.id,
    mediaId: row.mediaId,
    speciesId: row.speciesId,
    sightingId: row.sightingId,
    bboxX: row.bboxX,
    bboxY: row.bboxY,
    bboxWidth: row.bboxWidth,
    bboxHeight: row.bboxHeight,
    notes: row.notes,
    createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt),
  );
}
