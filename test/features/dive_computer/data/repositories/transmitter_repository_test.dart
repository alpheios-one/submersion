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
  });
}
