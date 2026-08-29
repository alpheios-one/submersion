import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/features/dive_log/domain/codecs/profile_sample.dart';
import 'package:submersion/features/dive_log/domain/codecs/profile_series_summary.dart';
import 'package:submersion/features/dive_log/domain/entities/profile_series.dart';

void main() {
  group('profileSeriesMigratedId', () {
    test('is deterministic over the identity tuple', () {
      final a = profileSeriesMigratedId(
        diveId: 'd1',
        computerId: 'c1',
        sourceId: 's1',
        isPrimary: true,
      );
      final b = profileSeriesMigratedId(
        diveId: 'd1',
        computerId: 'c1',
        sourceId: 's1',
        isPrimary: true,
      );
      expect(a, b);
      expect(a, hasLength(36));
      expect(a[14], '5', reason: 'uuid v5 version nibble');
    });

    test('every tuple member changes the id', () {
      final base = profileSeriesMigratedId(
        diveId: 'd1',
        computerId: 'c1',
        sourceId: 's1',
        isPrimary: true,
      );
      expect(
        profileSeriesMigratedId(
          diveId: 'd2',
          computerId: 'c1',
          sourceId: 's1',
          isPrimary: true,
        ),
        isNot(base),
      );
      expect(
        profileSeriesMigratedId(
          diveId: 'd1',
          computerId: null,
          sourceId: 's1',
          isPrimary: true,
        ),
        isNot(base),
      );
      expect(
        profileSeriesMigratedId(
          diveId: 'd1',
          computerId: 'c1',
          sourceId: null,
          isPrimary: true,
        ),
        isNot(base),
      );
      expect(
        profileSeriesMigratedId(
          diveId: 'd1',
          computerId: 'c1',
          sourceId: 's1',
          isPrimary: false,
        ),
        isNot(base),
      );
    });

    test('a literal "null" string and an absent member are distinct', () {
      // The key joins members with '|' and spells absence as `null`; a
      // computer literally named "null" must not collide with none.
      final absent = profileSeriesMigratedId(
        diveId: 'd1',
        computerId: null,
        sourceId: null,
        isPrimary: true,
      );
      final literal = profileSeriesMigratedId(
        diveId: 'd1',
        computerId: 'null',
        sourceId: null,
        isPrimary: true,
      );
      expect(absent, isNot(literal));
    });
  });

  group('tankPressureSeriesMigratedId', () {
    test('is deterministic and distinct from the profile namespace', () {
      final a = tankPressureSeriesMigratedId(
        diveId: 'd1',
        tankId: 't1',
        computerId: null,
      );
      final b = tankPressureSeriesMigratedId(
        diveId: 'd1',
        tankId: 't1',
        computerId: null,
      );
      expect(a, b);
      expect(
        a,
        isNot(
          profileSeriesMigratedId(
            diveId: 'd1',
            computerId: null,
            sourceId: 't1',
            isPrimary: true,
          ),
        ),
      );
    });
  });

  group('ProfileSeries', () {
    const samples = [
      ProfileSample(timestamp: 0, depth: 0.0),
      ProfileSample(timestamp: 10, depth: 12.5, temperature: 20.0),
    ];
    final series = ProfileSeries(
      id: 'ps1',
      diveId: 'd1',
      computerId: 'c1',
      sourceId: 's1',
      isPrimary: true,
      summary: ProfileSeriesSummary.of(samples),
      samples: samples,
      codecVersion: 1,
      createdAt: 1000,
      updatedAt: 1000,
    );

    test('points converts every sample to a DiveProfilePoint', () {
      final points = series.points;
      expect(points, hasLength(2));
      expect(points[1].timestamp, 10);
      expect(points[1].depth, 12.5);
      expect(points[1].temperature, 20.0);
    });

    test('copyWith replaces only what is given', () {
      final demoted = series.copyWith(isPrimary: false, updatedAt: 2000);
      expect(demoted.isPrimary, isFalse);
      expect(demoted.updatedAt, 2000);
      expect(demoted.id, 'ps1');
      expect(demoted.samples, samples);
      expect(demoted, isNot(series));
    });

    test('copyWith can clear nullable members', () {
      final cleared = series.copyWith(
        clearComputerId: true,
        clearSourceId: true,
      );
      expect(cleared.computerId, isNull);
      expect(cleared.sourceId, isNull);
    });
  });
}
