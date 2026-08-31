import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/constants/sort_options.dart';
import 'package:submersion/core/models/sort_state.dart';
import 'package:submersion/features/dive_sites/domain/entities/dive_site.dart';
import 'package:submersion/features/dive_sites/domain/entities/site_with_dive_count.dart';
import 'package:submersion/features/dive_sites/presentation/providers/site_providers.dart';

SiteWithDiveCount _site(
  String name, {
  int diveCount = 0,
  DateTime? lastDivedAt,
}) {
  return SiteWithDiveCount(
    site: DiveSite(id: 'id-$name', name: name),
    diveCount: diveCount,
    lastDivedAt: lastDivedAt,
  );
}

void main() {
  group('applySiteSorting - lastDived (issue #1263)', () {
    test('descending puts the most recently dived site first', () {
      final sites = [
        _site('Old', diveCount: 2, lastDivedAt: DateTime(2020, 5, 1)),
        _site('Recent', diveCount: 1, lastDivedAt: DateTime(2026, 3, 15)),
        _site('Middle', diveCount: 3, lastDivedAt: DateTime(2023, 8, 20)),
      ];

      final sorted = applySiteSorting(
        sites,
        const SortState(
          field: SiteSortField.lastDived,
          direction: SortDirection.descending,
        ),
      );

      expect(sorted.map((s) => s.site.name), ['Recent', 'Middle', 'Old']);
    });

    test('ascending puts the least recently dived site first', () {
      final sites = [
        _site('Recent', lastDivedAt: DateTime(2026, 3, 15)),
        _site('Old', lastDivedAt: DateTime(2020, 5, 1)),
        _site('Middle', lastDivedAt: DateTime(2023, 8, 20)),
      ];

      final sorted = applySiteSorting(
        sites,
        const SortState(
          field: SiteSortField.lastDived,
          direction: SortDirection.ascending,
        ),
      );

      expect(sorted.map((s) => s.site.name), ['Old', 'Middle', 'Recent']);
    });

    test('never-dived sites sort after dived sites when descending', () {
      final sites = [
        _site('Never'),
        _site('Recent', lastDivedAt: DateTime(2026, 3, 15)),
        _site('Old', lastDivedAt: DateTime(2020, 5, 1)),
      ];

      final sorted = applySiteSorting(
        sites,
        const SortState(
          field: SiteSortField.lastDived,
          direction: SortDirection.descending,
        ),
      );

      expect(sorted.map((s) => s.site.name), ['Recent', 'Old', 'Never']);
    });

    test('never-dived sites sort before dived sites when ascending', () {
      final sites = [
        _site('Recent', lastDivedAt: DateTime(2026, 3, 15)),
        _site('Never'),
        _site('Old', lastDivedAt: DateTime(2020, 5, 1)),
      ];

      final sorted = applySiteSorting(
        sites,
        const SortState(
          field: SiteSortField.lastDived,
          direction: SortDirection.ascending,
        ),
      );

      expect(sorted.map((s) => s.site.name), ['Never', 'Old', 'Recent']);
    });

    test('does not mutate the input list', () {
      final sites = [
        _site('B', lastDivedAt: DateTime(2020)),
        _site('A', lastDivedAt: DateTime(2026)),
      ];
      final original = List.of(sites);

      applySiteSorting(
        sites,
        const SortState(
          field: SiteSortField.lastDived,
          direction: SortDirection.descending,
        ),
      );

      expect(sites, original);
    });
  });

  group('applySiteSorting - existing fields still work', () {
    test('name descending is alphabetical A to Z', () {
      final sites = [_site('Charlie'), _site('Alice'), _site('Bob')];

      final sorted = applySiteSorting(
        sites,
        const SortState(
          field: SiteSortField.name,
          direction: SortDirection.descending,
        ),
      );

      expect(sorted.map((s) => s.site.name), ['Alice', 'Bob', 'Charlie']);
    });

    test('dive count descending puts highest count first', () {
      final sites = [
        _site('Low', diveCount: 1),
        _site('High', diveCount: 10),
        _site('Mid', diveCount: 5),
      ];

      final sorted = applySiteSorting(
        sites,
        const SortState(
          field: SiteSortField.diveCount,
          direction: SortDirection.descending,
        ),
      );

      expect(sorted.map((s) => s.site.name), ['High', 'Mid', 'Low']);
    });
  });
}
