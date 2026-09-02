import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/features/divers/domain/entities/diver_weight_entry.dart';
import 'package:submersion/features/divers/presentation/providers/diver_weight_entry_providers.dart';

void main() {
  DiverWeightEntry entry(String id, DateTime at, {double? heightCm}) =>
      DiverWeightEntry(
        id: id,
        diverId: 'diver-1',
        measuredAt: at,
        weightKg: 80,
        heightCm: heightCm,
        createdAt: at,
        updatedAt: at,
      );

  ProviderContainer containerWith(List<DiverWeightEntry> entries) {
    final c = ProviderContainer(
      overrides: [
        diverWeightEntriesProvider.overrideWith((ref) async => entries),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test(
    'latestDiverHeightProvider skips newer entries without a height',
    () async {
      final c = containerWith([
        entry('w3', DateTime(2026, 8, 1)),
        entry('w2', DateTime(2026, 7, 1), heightCm: 180),
        entry('w1', DateTime(2026, 6, 1), heightCm: 170),
      ]);
      expect(await c.read(latestDiverHeightProvider.future), 180);
    },
  );

  test(
    'latestDiverHeightProvider is null when no entry records a height',
    () async {
      final c = containerWith([entry('w1', DateTime(2026, 6, 1))]);
      expect(await c.read(latestDiverHeightProvider.future), isNull);
    },
  );

  test('latestDiverWeightProvider still returns the newest entry', () async {
    final c = containerWith([
      entry('w2', DateTime(2026, 7, 1)),
      entry('w1', DateTime(2026, 6, 1), heightCm: 170),
    ]);
    expect((await c.read(latestDiverWeightProvider.future))?.id, 'w2');
  });
}
