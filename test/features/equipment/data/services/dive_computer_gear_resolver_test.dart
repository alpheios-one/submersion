import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_test/flutter_test.dart';

import 'package:submersion/core/database/database.dart' hide DiveComputer;
import 'package:submersion/core/database/dive_computer_gear_identity.dart';
import 'package:submersion/features/dive_log/domain/entities/dive_computer.dart';
import 'package:submersion/features/equipment/data/services/dive_computer_gear_resolver.dart';

import '../../../../helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late DiveComputerGearResolver resolver;

  setUp(() async {
    db = await setUpTestDatabase();
    // Equipment writes without full Diver fixtures.
    await db.customStatement('PRAGMA foreign_keys = OFF');
    resolver = DiveComputerGearResolver();
  });
  tearDown(tearDownTestDatabase);

  DiveComputer computer({
    String id = 'c1',
    String? diverId = 'd1',
    String name = 'My Perdix',
    String? manufacturer = 'Shearwater',
    String? model = 'Perdix 2',
    String? serialNumber,
    String? equipmentId,
  }) => DiveComputer(
    id: id,
    diverId: diverId,
    name: name,
    manufacturer: manufacturer,
    model: model,
    serialNumber: serialNumber,
    equipmentId: equipmentId,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  );

  Future<void> insertGear(
    String id, {
    String? diverId = 'd1',
    String type = 'computer',
    String? brand,
    String? model,
    String? serialNumber,
    bool isActive = true,
  }) async {
    final t = DateTime.now().millisecondsSinceEpoch;
    await db
        .into(db.equipment)
        .insert(
          EquipmentCompanion.insert(
            id: id,
            diverId: Value(diverId),
            name: id,
            type: type,
            brand: Value(brand),
            model: Value(model),
            serialNumber: Value(serialNumber),
            isActive: Value(isActive),
            createdAt: t,
            updatedAt: t,
          ),
        );
  }

  Future<int> equipmentCount() async {
    final row = await db
        .customSelect('SELECT COUNT(*) AS c FROM equipment')
        .getSingle();
    return row.read<int>('c');
  }

  test('mints a twin at the deterministic id when nothing matches', () async {
    final id = await resolver.resolveGearTwin(computer());

    expect(id, diveComputerGearId('c1'));
    final row = await (db.select(
      db.equipment,
    )..where((t) => t.id.equals(id!))).getSingle();
    expect(row.type, 'computer');
    expect(row.name, 'My Perdix');
    expect(row.brand, 'Shearwater');
    expect(row.model, 'Perdix 2');
    // Seeded once, then owned by the user: service fields stay theirs to set.
    expect(row.purchaseDate, isNull);
    expect(row.serviceIntervalDays, isNull);
  });

  test('returns the stored link when its equipment row still exists', () async {
    await insertGear('hand-made');

    final id = await resolver.resolveGearTwin(
      computer(equipmentId: 'hand-made'),
    );

    expect(id, 'hand-made');
  });

  test('mints when the stored link points at a deleted row', () async {
    final id = await resolver.resolveGearTwin(computer(equipmentId: 'gone'));

    expect(id, diveComputerGearId('c1'));
  });

  test('adopts the row holding the derived id after a rename', () async {
    // The identity match reads the row's CURRENT text while the id derives
    // from the computer id, so renaming makes the match miss while the id
    // still collides. Without this branch the insert throws
    // SqliteException(1555) UNIQUE constraint failed.
    await insertGear(
      diveComputerGearId('c1'),
      brand: 'Totally',
      model: 'Renamed',
    );

    final id = await resolver.resolveGearTwin(computer());

    expect(id, diveComputerGearId('c1'));
    expect(await equipmentCount(), 1);
  });

  test('adopts an unambiguous hand-created gear item', () async {
    await insertGear('hand-made', brand: 'Shearwater', model: 'Perdix 2');

    final id = await resolver.resolveGearTwin(computer());

    expect(id, 'hand-made');
  });

  test('mints rather than guessing between two identical candidates', () async {
    await insertGear('one', brand: 'Shearwater', model: 'Perdix 2');
    await insertGear('two', brand: 'Shearwater', model: 'Perdix 2');

    final id = await resolver.resolveGearTwin(computer());

    expect(id, diveComputerGearId('c1'));
  });

  test('ignores retired gear and non-computer gear when matching', () async {
    await insertGear(
      'retired',
      brand: 'Shearwater',
      model: 'Perdix 2',
      isActive: false,
    );
    await insertGear(
      'a-bcd',
      type: 'bcd',
      brand: 'Shearwater',
      model: 'Perdix 2',
    );

    final id = await resolver.resolveGearTwin(computer());

    expect(id, diveComputerGearId('c1'));
  });

  test('is idempotent across repeated calls', () async {
    final first = await resolver.resolveGearTwin(computer());
    final second = await resolver.resolveGearTwin(computer());

    expect(first, second);
    expect(await equipmentCount(), 1);
  });

  test('returns null instead of throwing when the write fails', () async {
    // Registration must not fail because gear seeding did: a computer with no
    // twin is still a correctly registered computer. Dropping the table is the
    // cheapest way to make every query in the resolver throw.
    await db.customStatement('DROP TABLE equipment');

    expect(await resolver.resolveGearTwin(computer()), isNull);
  });
}
