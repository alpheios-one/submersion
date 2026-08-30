// Legacy sample entities (dive_profiles / tank_pressure_profiles) become
// inbound-only as of v182 (plan 2d, task 2): a device never exports its own
// row-per-sample data any more (it writes series instead, see plan 2b/2c),
// but an older peer that has not migrated yet still publishes row-per-sample
// arrays, and those must keep applying so its data is not silently dropped.
// A post-merge hook packs whatever legacy rows land locally into series.
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/data/repositories/sync_repository.dart';
import 'package:submersion/core/services/database_service.dart';
import 'package:submersion/core/services/sync/changeset_log/changeset_log_layout.dart';
import 'package:submersion/core/services/sync/changeset_log/sync_manifest.dart';
import 'package:submersion/core/services/sync/hlc.dart';
import 'package:submersion/core/services/sync/sync_data_serializer.dart';
import 'package:submersion/core/services/sync/sync_service.dart';
import 'package:submersion/features/dive_log/data/repositories/dive_repository_impl.dart';
import 'package:submersion/features/dive_log/data/repositories/profile_series_repository.dart';
import 'package:submersion/features/dive_log/domain/entities/dive.dart'
    as domain;
import 'package:submersion/features/dive_log/domain/entities/profile_series_identity.dart';

import '../../../helpers/fake_cloud_storage_provider.dart';
import '../../../helpers/test_database.dart';

domain.Dive _dive(String id, List<domain.DiveProfilePoint> profile) =>
    domain.Dive(id: id, dateTime: DateTime(2026, 1, 1), profile: profile);

const _twoPoints = [
  domain.DiveProfilePoint(timestamp: 0, depth: 5.0),
  domain.DiveProfilePoint(timestamp: 60, depth: 10.0),
];

void main() {
  group('export: legacy sample entities never leave this device', () {
    setUp(() async {
      await setUpTestDatabase();
    });

    tearDown(() => tearDownTestDatabase());

    test('exportChangeset carries no legacy sample entities', () async {
      await DiveRepository().createDive(_dive('d1', _twoPoints));
      final payload = await SyncDataSerializer().exportChangeset(
        deviceId: 'me',
        hlcWatermark: null,
        deletions: const [],
      );
      final data = payload.data;
      expect(data.toJson().containsKey('diveProfiles'), isFalse);
      expect(data.toJson().containsKey('tankPressureProfiles'), isFalse);
      expect(data.diveProfileSeries, hasLength(1));
    });

    test('SyncData.fromJson still parses the legacy keys', () {
      final data = SyncData.fromJson({
        'diveProfiles': [
          {'id': 'x'},
        ],
        'tankPressureProfiles': [
          {'id': 'y'},
        ],
      });
      expect(data.diveProfiles.single['id'], 'x');
      expect(data.tankPressureProfiles.single['id'], 'y');
    });
  });

  group('inbound: a peer publishing legacy sample rows', () {
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

    /// Publishes [dataJson] -- the raw `data` section a peer still on
    /// row-per-sample tables would send, legacy `diveProfiles` /
    /// `tankPressureProfiles` keys included -- as [peerId]'s single
    /// changeset (seq 1, no base) and pulls it through the real merge path.
    ///
    /// A base publish will not exercise the behavior under test: the
    /// streaming base-file apply (SyncService._applyRemoteBaseFile*) only
    /// reads tables named in `entityHasUpdatedAt`, and this task removes
    /// `diveProfiles`/`tankPressureProfiles` from that map (a table absent
    /// from it is silently skipped on base import -- see that map's doc
    /// comment). A changeset is instead applied in-memory through
    /// `mergeOrder`, which still lists both entities; this is exactly the
    /// path an already-known peer's incremental publish takes, so it is
    /// the one that must (and does) still apply and get packed.
    Future<void> pullPeerPayload(
      Map<String, dynamic> dataJson,
      String peerId,
    ) async {
      final checksum = sha256
          .convert(utf8.encode(jsonEncode(dataJson)))
          .toString();
      final payloadJson = <String, dynamic>{
        'version': syncFormatVersion,
        'exportedAt': 9000,
        'deviceId': peerId,
        'lastSyncTimestamp': null,
        'checksum': checksum,
        'data': dataJson,
        'deletions': <String, dynamic>{},
        'uploadNonce': null,
        'epochId': null,
        'seq': 1,
        'baseSeq': null,
        'sinceHlc': null,
        'toHlc': null,
      };
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(payloadJson)));
      final folder = await cloud.getOrCreateSyncFolder();
      await cloud.uploadFile(
        bytes,
        ChangesetLogLayout.changesetName(peerId, 1),
        folderId: folder,
      );
      final manifest = SyncManifest(
        deviceId: peerId,
        provider: cloud.providerId,
        headSeq: 1,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
      await cloud.uploadFile(
        manifest.toBytes(),
        ChangesetLogLayout.manifestName(peerId),
        folderId: folder,
      );
      final result = await buildService().performSync();
      expect(result.status, isNot(SyncResultStatus.error));
    }

    test(
      'a v181 peer payload with legacy rows for a new dive lands as a series',
      () async {
        await DiveRepository().createDive(_dive('template', const []));
        final diveRow =
            Map<String, dynamic>.from(
                (await SyncDataSerializer().fetchRecord('dives', 'template'))!,
              )
              ..['id'] = 'd-old'
              ..['hlc'] = const Hlc(9000, 0, 'peer-181').toString();
        final profiles = [
          {
            'id': 'p1',
            'diveId': 'd-old',
            'timestamp': 0,
            'depth': 0.0,
            'isPrimary': true,
          },
          {
            'id': 'p2',
            'diveId': 'd-old',
            'timestamp': 60,
            'depth': 12.0,
            'isPrimary': true,
          },
        ];
        final data = SyncData(dives: [diveRow], diveProfiles: profiles);
        // SyncData.fromJson(data.toJson()) would DROP diveProfiles (inbound
        // only), so build the payload data section by hand.
        final dataJson = {...data.toJson(), 'diveProfiles': profiles};

        await pullPeerPayload(dataJson, 'peer-181');

        final series = await ProfileSeriesRepository().getSeriesForDive(
          'd-old',
        );
        expect(series, hasLength(1));
        expect(series.single.samples.map((s) => s.depth), [0.0, 12.0]);
        expect(
          series.single.id,
          profileSeriesMigratedId(
            diveId: 'd-old',
            computerId: null,
            sourceId: null,
            isPrimary: true,
          ),
        );
      },
    );

    test(
      'legacy rows for a dive that already has series are ignored',
      () async {
        await DiveRepository().createDive(_dive('d1', _twoPoints));
        final before = (await ProfileSeriesRepository().getSeriesForDive(
          'd1',
        )).single;

        final profiles = [
          {
            'id': 'p-stale',
            'diveId': 'd1',
            'timestamp': 0,
            'depth': 99.0,
            'isPrimary': true,
          },
        ];
        final data = SyncData(diveProfiles: profiles);
        final dataJson = {...data.toJson(), 'diveProfiles': profiles};

        await pullPeerPayload(dataJson, 'peer-181b');

        final after = (await ProfileSeriesRepository().getSeriesForDive(
          'd1',
        )).single;
        expect(after.id, before.id);
        expect(
          after.samples.map((s) => s.depth),
          before.samples.map((s) => s.depth),
        );
      },
    );
  });
}
