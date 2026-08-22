import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/features/dive_log/data/repositories/dive_repository_impl.dart';
import 'package:submersion/features/dive_log/domain/entities/dive.dart'
    as domain;
import 'package:submersion/features/dive_log/domain/models/dive_filter_state.dart';

import '../../../../helpers/test_database.dart';

void main() {
  late DiveRepository repository;

  setUp(() async {
    await setUpTestDatabase();
    repository = DiveRepository();
  });
  tearDown(() async => tearDownTestDatabase());

  test(
    'decoOnly: true matches a recorded deco stop, decoOnly: false matches '
    'a recorded no-deco profile',
    () async {
      await repository.createDive(
        domain.Dive(
          id: 'deco',
          dateTime: DateTime(2026, 1, 1),
          profile: const [
            domain.DiveProfilePoint(timestamp: 0, depth: 30, decoType: 0),
            domain.DiveProfilePoint(timestamp: 60, depth: 30, decoType: 2),
          ],
        ),
      );
      await repository.createDive(
        domain.Dive(
          id: 'noDeco',
          dateTime: DateTime(2026, 1, 2),
          profile: const [
            domain.DiveProfilePoint(timestamp: 0, depth: 18, decoType: 0),
          ],
        ),
      );
      await repository.createDive(
        domain.Dive(id: 'unrecorded', dateTime: DateTime(2026, 1, 3)),
      );

      final decoResults = await repository.getDiveSummaries(
        filter: const DiveFilterState(decoOnly: true),
      );
      expect(decoResults.map((d) => d.id).toSet(), {'deco'});

      final noDecoResults = await repository.getDiveSummaries(
        filter: const DiveFilterState(decoOnly: false),
      );
      expect(noDecoResults.map((d) => d.id).toSet(), {'noDeco'});
    },
  );

  test('in-memory apply() agrees with the SQL path', () {
    final dives = [
      domain.Dive(
        id: 'deco',
        dateTime: DateTime(2026, 1, 1),
        profile: const [
          domain.DiveProfilePoint(timestamp: 0, depth: 30, decoType: 2),
        ],
      ),
      domain.Dive(
        id: 'noDeco',
        dateTime: DateTime(2026, 1, 2),
        profile: const [
          domain.DiveProfilePoint(timestamp: 0, depth: 18, decoType: 0),
        ],
      ),
    ];

    expect(
      const DiveFilterState(decoOnly: true).apply(dives).map((d) => d.id),
      ['deco'],
    );
    expect(
      const DiveFilterState(decoOnly: false).apply(dives).map((d) => d.id),
      ['noDeco'],
    );
  });
}
