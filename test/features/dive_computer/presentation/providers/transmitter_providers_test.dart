import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/database/database.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/dive_computer/domain/entities/transmitter_entity.dart';
import 'package:submersion/features/dive_computer/presentation/providers/transmitter_providers.dart';

import '../../../../helpers/test_database.dart';

/// `unassignedChannelIndexesForComputerProvider` (issue #1365 follow-up):
/// channels a download actually reported that have no registry entry yet,
/// so the "add mapping" dialog can offer a pick list instead of a free-text
/// index.
void main() {
  late AppDatabase db;

  setUp(() async {
    db = await setUpTestDatabase();
    final now = DateTime.now().millisecondsSinceEpoch;
    await db
        .into(db.diveComputers)
        .insert(
          DiveComputersCompanion(
            id: const Value('dc-1'),
            name: const Value('Test Computer'),
            createdAt: Value(now),
            updatedAt: Value(now),
          ),
        );
  });

  tearDown(() async {
    await tearDownTestDatabase();
  });

  Future<void> insertDiveTank({
    required String diveId,
    required int tankOrder,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await db
        .into(db.dives)
        .insert(
          DivesCompanion.insert(
            id: diveId,
            diveDateTime: now,
            createdAt: now,
            updatedAt: now,
          ),
          mode: InsertMode.insertOrIgnore,
        );
    await db
        .into(db.diveTanks)
        .insert(
          DiveTanksCompanion.insert(
            id: '$diveId-tank-$tankOrder',
            diveId: diveId,
            computerId: const Value('dc-1'),
            tankOrder: Value(tankOrder),
            source: const Value('dc_import'),
          ),
        );
  }

  test('returns nothing when no downloads have happened yet', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final result = await container.read(
      unassignedChannelIndexesForComputerProvider('dc-1').future,
    );

    expect(result, isEmpty);
  });

  test('lists channels seen in downloads with no registry entry', () async {
    await insertDiveTank(diveId: 'dive-1', tankOrder: 0);
    await insertDiveTank(diveId: 'dive-1', tankOrder: 1);
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final result = await container.read(
      unassignedChannelIndexesForComputerProvider('dc-1').future,
    );

    expect(result, [0, 1]);
  });

  test('drops channels that already have a registry entry', () async {
    await insertDiveTank(diveId: 'dive-1', tankOrder: 0);
    await insertDiveTank(diveId: 'dive-1', tankOrder: 1);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final now = DateTime.now();
    await container
        .read(transmitterRepositoryProvider)
        .upsert(
          TransmitterEntity(
            id: '',
            diveComputerId: 'dc-1',
            channelIndex: 0,
            createdAt: now,
            updatedAt: now,
          ),
        );

    final result = await container.read(
      unassignedChannelIndexesForComputerProvider('dc-1').future,
    );

    expect(result, [1]);
  });
}
