/// Regression coverage for issue #1355: opening the Dive List Fields page
/// pinned a CPU core and froze the app.
///
/// `tablePresetsProvider` subscribes to `watchPresetsChanges()` and then, in
/// the same build, calls `ensureBuiltInPresets()`. The seeding write landed on
/// `field_presets`, the tick fired, the provider invalidated itself, and the
/// rebuild seeded again -- an unbounded write/invalidate loop for as long as
/// anything listened to the provider.
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/database/database.dart' hide FieldPreset;
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/core/services/database_service.dart';
import 'package:submersion/features/dive_log/data/repositories/view_config_repository.dart';
import 'package:submersion/features/dive_log/presentation/providers/view_config_providers.dart';

/// Counts how many times the provider reaches the seeding write.
class _CountingViewConfigRepository extends ViewConfigRepository {
  _CountingViewConfigRepository(super.db);

  int ensureCalls = 0;

  @override
  Future<void> ensureBuiltInPresets(String diverId) {
    ensureCalls++;
    return super.ensureBuiltInPresets(diverId);
  }
}

void main() {
  late AppDatabase db;
  late _CountingViewConfigRepository repository;
  const diverId = 'diver-1355';

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repository = _CountingViewConfigRepository(db);
    DatabaseService.instance.setTestDatabase(db);

    final now = DateTime.now().millisecondsSinceEpoch;
    await db
        .into(db.divers)
        .insert(
          DiversCompanion(
            id: const Value(diverId),
            name: const Value('Test Diver'),
            createdAt: Value(now),
            updatedAt: Value(now),
          ),
        );
  });

  tearDown(() async {
    DatabaseService.instance.resetForTesting();
    await db.close();
  });

  test('tablePresetsProvider settles instead of re-seeding forever', () async {
    final container = ProviderContainer(
      overrides: [viewConfigRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(container.dispose);

    // A listener keeps the provider active, exactly like the open page.
    container.listen(
      tablePresetsProvider(diverId),
      (_, _) {},
      fireImmediately: true,
    );

    await container.read(tablePresetsProvider(diverId).future);
    // Let every queued invalidation drain.
    await Future<void>.delayed(const Duration(milliseconds: 300));

    // One seeding pass, plus at most one rebuild from the seeding write
    // itself. Anything beyond that is the runaway loop.
    expect(repository.ensureCalls, lessThanOrEqualTo(2));
  });

  test('two live divers settle instead of trading writes', () async {
    // The provider family is not autoDispose, so switching divers leaves both
    // instances alive. The built-in preset row carries one global id, so each
    // diver's seed rewrites the other's -- a real change, which a per-build
    // seed would bounce back and forth forever.
    const otherDiverId = 'diver-1355-b';
    final now = DateTime.now().millisecondsSinceEpoch;
    await db
        .into(db.divers)
        .insert(
          DiversCompanion(
            id: const Value(otherDiverId),
            name: const Value('Second Diver'),
            createdAt: Value(now),
            updatedAt: Value(now),
          ),
        );

    final container = ProviderContainer(
      overrides: [viewConfigRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(container.dispose);

    for (final id in [diverId, otherDiverId]) {
      container.listen(
        tablePresetsProvider(id),
        (_, _) {},
        fireImmediately: true,
      );
    }

    await container.read(tablePresetsProvider(diverId).future);
    await container.read(tablePresetsProvider(otherDiverId).future);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    // One seeding pass per diver; neither reacts to the other's write by
    // seeding again.
    expect(repository.ensureCalls, lessThanOrEqualTo(2));
  });

  test('ensureBuiltInPresets does not rewrite unchanged built-ins', () async {
    await repository.ensureBuiltInPresets(diverId);
    final seeded = await db.select(db.fieldPresets).get();
    expect(seeded, isNotEmpty);

    var ticks = 0;
    final sub = repository.watchPresetsChanges().listen((_) => ticks++);
    addTearDown(sub.cancel);
    // Drop the tick drift emits on subscribe.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    ticks = 0;

    await repository.ensureBuiltInPresets(diverId);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(ticks, isZero, reason: 'a no-op reseed must not fire a table tick');
    final after = await db.select(db.fieldPresets).get();
    expect(
      after.map((r) => r.createdAt).toList(),
      equals(seeded.map((r) => r.createdAt).toList()),
      reason: 'createdAt must survive a reseed',
    );
  });
}
