import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/features/dive_log/domain/entities/dive.dart';
import 'package:submersion/features/dive_log/domain/entities/dive_data_source.dart';
import 'package:submersion/features/dive_log/domain/entities/source_profile.dart';
import 'package:submersion/features/dive_log/presentation/providers/active_source_provider.dart';
import 'package:submersion/features/dive_log/presentation/providers/dive_providers.dart';

/// Regression cover for #543.
///
/// A consolidated dive keeps every computer's samples, and `dive.profile` is
/// the union of them interleaved by timestamp. Any surface that draws that
/// union zig-zags between the two computers' readings. This provider is the
/// single rule for "which series does the chart draw": the active (or
/// primary) source's own samples on a multi-source dive, nothing otherwise so
/// callers fall back to `dive.profile`.
void main() {
  const diveId = 'dive-1';
  final now = DateTime(2026, 7, 13);

  DiveDataSource source(
    String id, {
    required bool isPrimary,
    String? computer,
  }) {
    return DiveDataSource(
      id: id,
      diveId: diveId,
      computerId: computer,
      isPrimary: isPrimary,
      importedAt: now,
      createdAt: now,
    );
  }

  const pointsA = [
    DiveProfilePoint(timestamp: 0, depth: 0.0, temperature: 15.0),
    DiveProfilePoint(timestamp: 10, depth: 5.0, temperature: 15.0),
  ];
  const pointsB = [
    DiveProfilePoint(timestamp: 0, depth: 0.0, temperature: 16.5),
    DiveProfilePoint(timestamp: 1, depth: 0.5, temperature: 16.5),
    DiveProfilePoint(timestamp: 2, depth: 1.0, temperature: 16.5),
  ];

  final twoSources = [
    source('src-a', isPrimary: true, computer: 'dc-a'),
    // A Shearwater Cloud file import has no registered computer.
    source('src-b', isPrimary: false),
  ];
  final twoProfiles = {
    'src-a': const SourceProfile(
      sourceId: 'src-a',
      computerId: 'dc-a',
      isEdited: false,
      points: pointsA,
    ),
    'src-b': const SourceProfile(
      sourceId: 'src-b',
      computerId: null,
      isEdited: false,
      points: pointsB,
    ),
  };

  Future<ProviderContainer> containerWith({
    required List<DiveDataSource> sources,
    required Map<String, SourceProfile> profiles,
    String? activeSourceId,
    bool resolve = true,
  }) async {
    final container = ProviderContainer(
      overrides: [
        diveDataSourcesProvider(diveId).overrideWith((ref) async => sources),
        sourceProfilesProvider(diveId).overrideWith((ref) async => profiles),
        if (activeSourceId != null)
          activeDiveSourceProvider(
            diveId,
          ).overrideWith((ref) => activeSourceId),
      ],
    );
    addTearDown(container.dispose);
    // Keep the autoDispose family member alive across the awaits below.
    container.listen(activeSourceProfileProvider(diveId), (_, _) {});
    if (resolve) {
      await container.read(diveDataSourcesProvider(diveId).future);
      await container.read(sourceProfilesProvider(diveId).future);
    }
    return container;
  }

  test(
    'a single-source dive resolves to null so callers draw dive.profile',
    () async {
      final container = await containerWith(
        sources: [source('src-a', isPrimary: true, computer: 'dc-a')],
        profiles: {'src-a': twoProfiles['src-a']!},
      );

      expect(container.read(activeSourceProfileProvider(diveId)), isNull);
    },
  );

  test('a multi-source dive defaults to the primary source', () async {
    final container = await containerWith(
      sources: twoSources,
      profiles: twoProfiles,
    );

    final profile = container.read(activeSourceProfileProvider(diveId));
    expect(profile?.sourceId, 'src-a');
    expect(profile?.computerId, 'dc-a');
    expect(profile?.points, pointsA);
  });

  test('an active selection wins over the primary', () async {
    final container = await containerWith(
      sources: twoSources,
      profiles: twoProfiles,
      activeSourceId: 'src-b',
    );

    final profile = container.read(activeSourceProfileProvider(diveId));
    expect(profile?.sourceId, 'src-b');
    expect(profile?.points, pointsB);
  });

  test('a stale active id falls back to the primary', () async {
    final container = await containerWith(
      sources: twoSources,
      profiles: twoProfiles,
      activeSourceId: 'src-gone',
    );

    expect(
      container.read(activeSourceProfileProvider(diveId))?.sourceId,
      'src-a',
    );
  });

  test(
    'a multi-source dive with no primary flag uses the first source',
    () async {
      final container = await containerWith(
        sources: [
          source('src-a', isPrimary: false, computer: 'dc-a'),
          source('src-b', isPrimary: false),
        ],
        profiles: twoProfiles,
      );

      expect(
        container.read(activeSourceProfileProvider(diveId))?.sourceId,
        'src-a',
      );
    },
  );

  test('resolves to null while the sources are still loading', () async {
    final container = await containerWith(
      sources: twoSources,
      profiles: twoProfiles,
      resolve: false,
    );

    expect(container.read(activeSourceProfileProvider(diveId)), isNull);
  });
}
