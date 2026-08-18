// Characterization tests for cross-version sync (issue #1089).
//
// A peer on an older schema (the App Store fleet during an Apple review
// window) republishes rows WITHOUT the columns its build does not know.
// These tests freeze the receiving-side behavior that makes that safe:
//  - the #474 overlay refills omitted keys from the local row,
//  - a tied HLC keeps local (an unedited old-peer snapshot applies nothing),
//  - rows created on the old device apply with newer columns as null.
// The compatibility floor (AppDatabase.minimumCompatibleSchemaVersion)
// asserts this safety; when a migration raises the floor, extend
// postV137DiveKeys and add the analogous projection for the new boundary.
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/data/repositories/sync_repository.dart';
import 'package:submersion/core/services/database_service.dart';
import 'package:submersion/core/services/sync/hlc.dart';
import 'package:submersion/core/services/sync/sync_data_serializer.dart';
import 'package:submersion/core/services/sync/sync_service.dart';
import 'package:submersion/features/dive_log/data/repositories/dive_repository_impl.dart';

import '../../../helpers/changeset_test_helpers.dart';
import '../../../helpers/fake_cloud_storage_provider.dart';
import '../../../helpers/mock_providers.dart';
import '../../../helpers/test_database.dart';

/// The dives-table JSON keys a schema-137 (v1.7.2) build does not know.
/// From the migration ladder: v144 added dives.visibility_meters; no other
/// dives column landed between 138 and 153. Extend this list when a later
/// migration adds a dives column, so the projection stays a faithful model
/// of what the oldest supported reader republishes.
const postV137DiveKeys = ['visibilityMeters'];

void main() {
  group('v137 peer round-trip through the real merge path (#1089)', () {
    late FakeCloudStorageProvider cloud;

    setUp(() async {
      await setUpTestDatabase();
      cloud = FakeCloudStorageProvider();
    });

    tearDown(() => DatabaseService.instance.resetForTesting());

    SyncService buildService() => SyncService(
      syncRepository: SyncRepository(),
      serializer: SyncDataSerializer(),
      cloudProvider: cloud,
    );

    /// Seeds a synced (non-pending) dive carrying a post-137 column value,
    /// returning its full exported JSON: the row as this newer device would
    /// publish it.
    Future<Map<String, dynamic>> seedModernDive(String id) async {
      await DiveRepository().createDive(
        createTestDiveWithBottomTime(id: id).copyWith(name: 'Original Name'),
      );
      final db = DatabaseService.instance.database;
      await db.customStatement(
        'UPDATE dives SET visibility_meters = 12.5 WHERE id = ?',
        [id],
      );
      final row = await SyncDataSerializer().fetchRecord('dives', id);
      expect(row!['visibilityMeters'], 12.5, reason: 'precondition');
      expect(row['hlc'], isNotNull, reason: 'precondition: row is clocked');
      await SyncRepository().resetSyncState();
      return Map<String, dynamic>.from(row);
    }

    /// Projects [row] onto the v137 dives schema: exactly what a 1.7.2 device
    /// ends up storing (fromJson ignores unknown keys) and later re-exporting
    /// (its row genuinely lacks the newer columns, so their keys are absent).
    Map<String, dynamic> asV137Peer(Map<String, dynamic> row) {
      final projected = Map<String, dynamic>.from(row);
      for (final key in postV137DiveKeys) {
        projected.remove(key);
      }
      return projected;
    }

    /// Publishes [diveRow] as peer `peer-137`'s data and pulls it through the
    /// full real pipeline (performSync, _mergeEntity, overlay, upsert).
    Future<void> pullPeerDive(Map<String, dynamic> diveRow) async {
      final data = SyncData(dives: [diveRow]);
      final payload = SyncPayload(
        version: syncFormatVersion,
        exportedAt: 9000,
        deviceId: 'peer-137',
        checksum: sha256
            .convert(utf8.encode(jsonEncode(data.toJson())))
            .toString(),
        data: data,
        deletions: const {},
      );
      await seedPeerBaseFromPayload(cloud, 'peer-137', payload);
      final result = await buildService().performSync();
      // A per-row apply failure flips the whole run to error, so this
      // assertion covers recordsFailed too.
      expect(result.status, isNot(SyncResultStatus.error));
    }

    test('old-peer edit applies AND the post-137 column survives', () async {
      final row = await seedModernDive('dive-xver');

      // The v137 peer edits the dive: its republished row carries only v137
      // keys, the edit, and a strictly-greater HLC minted by its own clock.
      final peerRow = asV137Peer(row)
        ..['name'] = 'Renamed on old device'
        ..['hlc'] = Hlc(
          Hlc.parse(row['hlc'] as String).physicalTime + 60000,
          0,
          'peer-137',
        ).toString()
        ..['updatedAt'] = (row['updatedAt'] as int) + 60000;

      await pullPeerDive(peerRow);

      final after = await SyncDataSerializer().fetchRecord(
        'dives',
        'dive-xver',
      );
      expect(
        after!['name'],
        'Renamed on old device',
        reason: 'the old peer legitimately won LWW; its edit must apply',
      );
      expect(
        after['visibilityMeters'],
        12.5,
        reason: 'THE HAZARD: the column the old peer never knew must survive',
      );
    });

    test(
      'tied-HLC republish (unedited old-peer snapshot) applies nothing',
      () async {
        final row = await seedModernDive('dive-tie');

        // The old peer republishes its full base without editing: same HLC.
        final peerRow = asV137Peer(row)..['name'] = 'Should Not Apply';

        await pullPeerDive(peerRow);

        final after = await SyncDataSerializer().fetchRecord(
          'dives',
          'dive-tie',
        );
        expect(
          after!['name'],
          'Original Name',
          reason: 'a tied HLC keeps local; nothing applies',
        );
        expect(after['visibilityMeters'], 12.5);
      },
    );

    test('row CREATED on the old device applies cleanly', () async {
      final template = await seedModernDive('dive-template');

      // A brand-new dive logged on the v137 device: no post-137 keys at all,
      // an id this device has never seen, the old device's own clock.
      final peerRow = asV137Peer(template)
        ..['id'] = 'dive-born-on-137'
        ..['name'] = 'Logged on old device'
        ..['hlc'] = Hlc(
          Hlc.parse(template['hlc'] as String).physicalTime + 60000,
          0,
          'peer-137',
        ).toString();

      await pullPeerDive(peerRow);

      final after = await SyncDataSerializer().fetchRecord(
        'dives',
        'dive-born-on-137',
      );
      expect(after, isNotNull, reason: 'the new row must apply');
      expect(after!['name'], 'Logged on old device');
      expect(
        after['visibilityMeters'],
        isNull,
        reason: 'nullable post-137 column backfills as null, not garbage',
      );
    });
  });
}
