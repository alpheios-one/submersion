import 'package:drift/drift.dart' show TableUpdateQuery;
import 'package:submersion/core/database/database.dart' as db_schema;
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/features/dive_log/data/repositories/dive_repository_impl.dart';
import 'package:submersion/features/dive_log/domain/entities/dive.dart';
import 'package:submersion/features/media/data/repositories/media_repository.dart';
import 'package:submersion/features/media/domain/entities/media_item.dart';
import 'package:submersion/features/media/domain/entities/media_source_type.dart';

import '../../../../helpers/test_database.dart';

/// Guards the batched write path the enrichment backfill uses.
///
/// The viewer's backfill used to save each enrichment row with its own
/// [MediaRepository.saveEnrichment] call. Every save is a separate top-level
/// write, so a dive with N un-enriched photos produced N mediaEnrichment
/// table ticks in a burst, each one (after the 300ms debounce window
/// re-opened) re-running every media provider that watches
/// `watchMediaChanges` -- the library re-query included. [saveEnrichments]
/// exists so the whole backfill commits as ONE transaction and lands as ONE
/// tick.
void main() {
  late db_schema.AppDatabase db;
  late MediaRepository repository;
  late DiveRepository diveRepository;

  setUp(() async {
    db = await setUpTestDatabase();
    repository = MediaRepository();
    diveRepository = DiveRepository();
  });

  tearDown(() async {
    await tearDownTestDatabase();
  });

  MediaEnrichment enrichmentFor(String mediaId) => MediaEnrichment(
    id: '',
    mediaId: mediaId,
    diveId: 'd1',
    depthMeters: 18.0,
    temperatureCelsius: 24.0,
    elapsedSeconds: 600,
    matchConfidence: MatchConfidence.exact,
    timestampOffsetSeconds: 0,
    createdAt: DateTime.utc(2026, 3, 28),
  );

  Future<void> seedDiveAndMedia(List<String> mediaIds) async {
    await diveRepository.createDive(
      Dive(id: 'd1', diveNumber: 1, dateTime: DateTime.utc(2026, 3, 28)),
    );
    for (final id in mediaIds) {
      await repository.createMedia(
        MediaItem(
          id: id,
          diveId: 'd1',
          mediaType: MediaType.photo,
          sourceType: MediaSourceType.localFile,
          takenAt: DateTime.utc(2026, 3, 28, 10),
          createdAt: DateTime.utc(2026, 3, 28),
          updatedAt: DateTime.utc(2026, 3, 28),
        ),
      );
    }
  }

  test('saveEnrichments persists every row and marks each pending', () async {
    await seedDiveAndMedia(['m1', 'm2', 'm3']);

    await repository.saveEnrichments([
      enrichmentFor('m1'),
      enrichmentFor('m2'),
      enrichmentFor('m3'),
    ]);

    for (final mediaId in ['m1', 'm2', 'm3']) {
      final stored = await repository.getEnrichmentForMedia(mediaId);
      expect(stored, isNotNull, reason: '$mediaId enrichment must persist');
      expect(stored!.elapsedSeconds, 600);
    }

    final pending = await db.select(db.syncRecords).get();
    expect(
      pending.where((r) => r.entityType == 'mediaEnrichment').length,
      3,
      reason: 'each batched row still syncs like an individual save',
    );
  });

  test('a batch of enrichments lands as a single table tick', () async {
    await seedDiveAndMedia(['m1', 'm2', 'm3']);

    var ticks = 0;
    final sub = db
        .tableUpdates(TableUpdateQuery.onTable(db.mediaEnrichment))
        .listen((_) => ticks++);
    addTearDown(sub.cancel);

    await repository.saveEnrichments([
      enrichmentFor('m1'),
      enrichmentFor('m2'),
      enrichmentFor('m3'),
    ]);

    // Drift dispatches table notifications per top-level statement; give any
    // extra (wrong) emissions ample time to arrive before counting.
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(
      ticks,
      1,
      reason:
          'The whole batch must commit as one transaction and therefore one '
          'tick. One tick per row is what turned the enrichment backfill '
          'into a media-provider invalidation storm after viewing a photo.',
    );
  });

  test('an empty batch writes nothing and ticks nothing', () async {
    var ticks = 0;
    final sub = db
        .tableUpdates(TableUpdateQuery.onTable(db.mediaEnrichment))
        .listen((_) => ticks++);
    addTearDown(sub.cancel);

    await repository.saveEnrichments(const []);

    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(ticks, 0);
  });
}
