import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/providers/provider.dart';
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
    bool sourcesResolve = true,
    bool profilesResolve = true,
  }) async {
    // Never-completing futures model the two loading windows: before the
    // data sources arrive, and between them and the per-source profiles.
    final pendingSources = Completer<List<DiveDataSource>>();
    final pendingProfiles = Completer<Map<String, SourceProfile>>();
    final container = ProviderContainer(
      overrides: [
        diveDataSourcesProvider(diveId).overrideWith(
          (ref) =>
              sourcesResolve ? Future.value(sources) : pendingSources.future,
        ),
        sourceProfilesProvider(diveId).overrideWith(
          (ref) =>
              profilesResolve ? Future.value(profiles) : pendingProfiles.future,
        ),
        if (activeSourceId != null)
          activeDiveSourceProvider(
            diveId,
          ).overrideWith((ref) => activeSourceId),
      ],
    );
    addTearDown(container.dispose);
    // Keep the autoDispose family member alive across the awaits below.
    container.listen(activeSourceProfileProvider(diveId), (_, _) {});
    if (sourcesResolve) {
      await container.read(diveDataSourcesProvider(diveId).future);
    }
    if (profilesResolve) {
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

  test('a multi-source dive whose profiles are still loading resolves to an '
      'empty profile for the active source, never dive.profile', () async {
    final container = await containerWith(
      sources: twoSources,
      profiles: twoProfiles,
      profilesResolve: false,
    );

    final profile = container.read(activeSourceProfileProvider(diveId));
    expect(profile, isNotNull);
    expect(profile!.sourceId, 'src-a');
    expect(profile.computerId, 'dc-a');
    expect(profile.points, isEmpty);
  });

  test('a reload of the data sources keeps a consolidated dive classified as '
      'multi-source, never falling back to dive.profile', () async {
    // A DEPENDENCY-driven reload, which is how this happens in the app: the
    // data sources watch the dive detail change tick, so any write behind the
    // chart (the first-view safety review, a media write, a dive edit) puts
    // them back into loading with their previous value retained. The
    // distinction matters: AsyncValue.when defaults to
    // skipLoadingOnRefresh: true but skipLoadingOnReload: false, so a getter
    // built on `when` keeps the value through container.refresh and drops it
    // here. Read that way the dive looks single-source for the frame, and
    // callers draw dive.profile: on a consolidated dive, the merged union and
    // the #543 sawtooth.
    final tick = StateProvider<int>((ref) => 0);
    final container = ProviderContainer(
      overrides: [
        diveDataSourcesProvider(diveId).overrideWith((ref) {
          ref.watch(tick);
          return Future.value(twoSources);
        }),
        sourceProfilesProvider(
          diveId,
        ).overrideWith((ref) => Future.value(twoProfiles)),
      ],
    );
    addTearDown(container.dispose);
    container.listen(activeSourceProfileProvider(diveId), (_, _) {});
    await container.read(diveDataSourcesProvider(diveId).future);
    await container.read(sourceProfilesProvider(diveId).future);
    expect(
      container.read(activeSourceProfileProvider(diveId))?.sourceId,
      'src-a',
      reason: 'baseline: the resolved state draws the primary',
    );

    container.read(tick.notifier).state = 1;
    final reloading = container.read(diveDataSourcesProvider(diveId));
    expect(reloading.isReloading, isTrue, reason: 'the reload window is open');
    expect(reloading.hasValue, isTrue, reason: 'the previous value is kept');

    final duringReload = container.read(activeSourceProfileProvider(diveId));
    expect(
      duringReload,
      isNotNull,
      reason: 'null here draws the merged union for a frame (#543)',
    );
    expect(duringReload!.sourceId, 'src-a');
    expect(duringReload.points, pointsA);
  });

  test('resolves to null while the data sources are still loading', () async {
    final container = await containerWith(
      sources: twoSources,
      profiles: twoProfiles,
      sourcesResolve: false,
    );

    expect(container.read(activeSourceProfileProvider(diveId)), isNull);
  });
}
