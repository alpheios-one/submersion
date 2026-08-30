import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/database/database.dart';
import 'package:submersion/features/dive_computer/data/repositories/transmitter_repository.dart';
import 'package:submersion/features/dive_computer/domain/entities/transmitter_entity.dart';

import '../../../../helpers/test_database.dart';

void main() {
  group('TransmitterRepository', () {
    late TransmitterRepository repository;
    late AppDatabase db;

    setUp(() async {
      db = await setUpTestDatabase();
      repository = TransmitterRepository();

      final now = DateTime.now().millisecondsSinceEpoch;
      await db
          .into(db.diveComputers)
          .insert(
            DiveComputersCompanion.insert(
              id: 'dc-1',
              name: 'Test Computer',
              createdAt: now,
              updatedAt: now,
            ),
          );
    });

    tearDown(() async {
      await tearDownTestDatabase();
    });

    TransmitterEntity entry({
      required int channelIndex,
      String? label,
      String? tankRole,
    }) {
      final now = DateTime.now();
      return TransmitterEntity(
        id: '',
        diveComputerId: 'dc-1',
        channelIndex: channelIndex,
        label: label,
        tankRole: tankRole,
        createdAt: now,
        updatedAt: now,
      );
    }

    test('upsert creates a new registry entry with a generated id', () async {
      final created = await repository.upsert(
        entry(channelIndex: 0, label: 'Back gas', tankRole: 'backGas'),
      );

      expect(created.id, isNotEmpty);
      expect(created.channelIndex, 0);
      expect(created.label, 'Back gas');

      final all = await repository.getForComputer('dc-1');
      expect(all, hasLength(1));
      expect(all.first.tankRole, 'backGas');
    });

    test(
      'upsert on an existing channel updates rather than duplicates',
      () async {
        final first = await repository.upsert(
          entry(channelIndex: 1, label: 'A'),
        );
        final second = await repository.upsert(
          entry(channelIndex: 1, label: 'B'),
        );

        expect(second.id, first.id);
        final all = await repository.getForComputer('dc-1');
        expect(all, hasLength(1));
        expect(all.first.label, 'B');
      },
    );

    test('getForChannel returns null when no entry exists', () async {
      final result = await repository.getForChannel('dc-1', 5);
      expect(result, isNull);
    });

    test('getForComputer orders by channel index', () async {
      await repository.upsert(entry(channelIndex: 2));
      await repository.upsert(entry(channelIndex: 0));
      await repository.upsert(entry(channelIndex: 1));

      final all = await repository.getForComputer('dc-1');
      expect(all.map((e) => e.channelIndex).toList(), [0, 1, 2]);
    });

    test('delete removes the entry', () async {
      final created = await repository.upsert(entry(channelIndex: 3));
      await repository.delete(created.id);

      final all = await repository.getForComputer('dc-1');
      expect(all, isEmpty);
    });

    test(
      'deleting the dive computer cascades to its registry entries',
      () async {
        await repository.upsert(entry(channelIndex: 0));
        await (db.delete(
          db.diveComputers,
        )..where((t) => t.id.equals('dc-1'))).go();

        final all = await repository.getForComputer('dc-1');
        expect(all, isEmpty);
      },
    );

    test('methods rethrow when the database is closed', () async {
      await db.close();

      await expectLater(repository.getForComputer('dc-1'), throwsA(anything));
    });

    group('getUsedChannelIndexes', () {
      Future<void> insertDiveTank({
        required String diveId,
        required int tankOrder,
        String? source,
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
                source: Value(source),
              ),
            );
      }

      test('returns distinct dc_import channels, ascending', () async {
        await insertDiveTank(
          diveId: 'dive-1',
          tankOrder: 1,
          source: 'dc_import',
        );
        await insertDiveTank(
          diveId: 'dive-2',
          tankOrder: 0,
          source: 'dc_import',
        );
        // Same channel seen again on a second dive must not duplicate.
        await insertDiveTank(
          diveId: 'dive-3',
          tankOrder: 1,
          source: 'dc_import',
        );

        final channels = await repository.getUsedChannelIndexes('dc-1');
        expect(channels, [0, 1]);
      });

      test('excludes manual and file-import rows', () async {
        await insertDiveTank(diveId: 'dive-1', tankOrder: 0, source: 'manual');
        await insertDiveTank(
          diveId: 'dive-2',
          tankOrder: 1,
          source: 'file_import',
        );

        final channels = await repository.getUsedChannelIndexes('dc-1');
        expect(channels, isEmpty);
      });

      test('returns empty for a computer with no downloads', () async {
        final channels = await repository.getUsedChannelIndexes('dc-1');
        expect(channels, isEmpty);
      });
    });
  });
}
