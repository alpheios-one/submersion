import 'package:flutter_test/flutter_test.dart';

import 'package:submersion/core/database/database.dart';
import 'package:submersion/core/services/sync/sync_data_serializer.dart';
import 'package:submersion/features/nav_track/data/repositories/nav_track_repository.dart';
import 'package:submersion/features/nav_track/domain/entities/nav_track.dart';
import 'package:submersion/features/nav_track/domain/entities/nav_track_point.dart';

import '../../../helpers/test_database.dart';

/// Design spec 2026-09-10-underwater-nav-track-design.md, "Sync, backup,
/// reset": "A dive deleted on one device arrives as a tombstone on the
/// other; the route's diveId must be cleared there too (the SET NULL
/// cascade fires locally when the dive row is removed; verify the sync
/// delete path deletes the row rather than soft-marking it, else clear the
/// link explicitly)."
///
/// [SyncDataSerializer.deleteRecord] applies an incoming dive tombstone with
/// a real SQL DELETE (`case 'dives': await (_db.delete(_db.dives)...)`), so
/// with `PRAGMA foreign_keys = ON` the `nav_tracks.dive_id` column's
/// `onDelete: KeyAction.setNull` fires automatically -- no explicit unlink
/// code is needed in the sync-apply path. This test proves it end to end
/// through the same call the sync merge uses to apply a dive tombstone.
Future<void> _insertMinimalDive(AppDatabase db, String id) {
  return db.customStatement(
    "INSERT INTO dives (id, dive_date_time, created_at, updated_at) "
    "VALUES ('$id', 1700000000000, 1, 1)",
  );
}

void main() {
  late AppDatabase db;
  late NavTrackRepository repo;
  late SyncDataSerializer serializer;

  setUp(() async {
    db = await setUpTestDatabase();
    await db.customStatement('PRAGMA foreign_keys = ON');
    repo = NavTrackRepository();
    serializer = SyncDataSerializer();
  });

  tearDown(tearDownTestDatabase);

  test(
    'applying an incoming dive tombstone clears the linked route\'s diveId',
    () async {
      await _insertMinimalDive(db, 'd1');
      final routeId = await repo.insertImportedRoute(
        points: const [
          NavTrackPoint(timestamp: 1700000000, north: 0, east: 0, depth: 1.7),
          NavTrackPoint(timestamp: 1700000010, north: 10, east: 5, depth: 5.2),
        ],
        source: NavTrackSource.seacraftEnc,
        sourceRef: '008.DAT.csv',
        diveId: 'd1',
      );

      var route = await repo.getById(routeId, includePoints: false);
      expect(route!.diveId, 'd1');

      // Simulate the sync merge applying an incoming dive-deletion tombstone
      // from another device: it calls deleteRecord('dives', id), exactly
      // like resolveConflict's keepRemote-deletion branch and the merge's
      // own tombstone application do.
      await serializer.deleteRecord('dives', 'd1');

      route = await repo.getById(routeId, includePoints: false);
      expect(route, isNotNull);
      expect(
        route!.diveId,
        isNull,
        reason:
            'the dive FK is declared onDelete: KeyAction.setNull, so a real '
            'SQL DELETE of the dive row must clear nav_tracks.dive_id',
      );
      // The recording itself is untouched, just unlinked -- it stays visible
      // in the routes area, ready to be matched again.
      expect(route.pointCount, 2);
    },
  );
}
