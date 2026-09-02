import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/dive_log/domain/entities/dive.dart';
import 'package:submersion/features/dive_log/domain/entities/dive_data_source.dart';
import 'package:submersion/features/dive_log/domain/entities/gas_switch.dart';
import 'package:submersion/features/dive_log/domain/entities/source_profile.dart';
import 'package:submersion/features/dive_log/presentation/pages/dive_detail_page.dart';
import 'package:submersion/features/dive_log/presentation/providers/dive_computer_providers.dart';
import 'package:submersion/features/dive_log/presentation/providers/dive_providers.dart';
import 'package:submersion/features/dive_log/presentation/providers/gas_switch_providers.dart';
import 'package:submersion/features/dive_log/presentation/widgets/dive_profile_chart.dart';
import 'package:submersion/features/dive_log/presentation/widgets/source_bar.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

import '../../../../helpers/mock_providers.dart';

/// Issue #1451: a dive a computer logged as two, stitched back together by
/// Combine, must draw as one continuous profile. Its carried provenance rows
/// are consecutive slices of one timeline, not alternative recordings, so the
/// page must not offer them as switchable sources and draw only the active
/// slice.
void main() {
  final now = DateTime(2026, 5, 7);

  /// A descend-and-ascend segment of [count] samples, one a minute, starting
  /// at [startSeconds].
  List<DiveProfilePoint> segment(int count, {required int startSeconds}) {
    return List.generate(
      count,
      (i) => DiveProfilePoint(
        timestamp: startSeconds + i * 60,
        depth: (i < count / 2 ? i : (count - 1 - i)) * 3.0,
      ),
    );
  }

  final firstHalf = segment(6, startSeconds: 0);
  final secondHalf = segment(6, startSeconds: 900);

  DiveDataSource carriedSource(String id) => DiveDataSource(
    id: id,
    diveId: 'test-dive-1',
    // A file or cloud import has no computer to collapse the halves on;
    // that is the case that reached the page as two selectable sources.
    computerId: null,
    isPrimary: false,
    sourceFileFormat: 'uddf',
    importedAt: now,
    createdAt: now,
  );

  late Dive dive;
  late List<DiveDataSource> sources;
  late Map<String, SourceProfile> profiles;

  setUp(() {
    dive = createTestDiveWithBottomTime().copyWith(
      profile: [...firstHalf, ...secondHalf],
    );
    sources = [carriedSource('src-first'), carriedSource('src-second')];
    profiles = {
      'src-first': SourceProfile(
        sourceId: 'src-first',
        computerId: null,
        isEdited: false,
        points: firstHalf,
      ),
      'src-second': SourceProfile(
        sourceId: 'src-second',
        computerId: null,
        isEdited: false,
        points: secondHalf,
      ),
    };
  });

  Future<void> pumpPage(WidgetTester tester) async {
    final base = await getBaseOverrides();
    final originalOnError = FlutterError.onError;
    FlutterError.onError = (d) {
      if (d.toString().contains('overflowed')) return;
      originalOnError?.call(d);
    };
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...base,
          diveProvider(dive.id).overrideWith((ref) async => dive),
          diveDataSourcesProvider(dive.id).overrideWith((ref) async => sources),
          sourceProfilesProvider(dive.id).overrideWith((ref) async => profiles),
          gasSwitchesProvider(
            dive.id,
          ).overrideWith((ref) async => <GasSwitchWithTank>[]),
          tankPressuresProvider(
            dive.id,
          ).overrideWith((ref) async => <String, List<TankPressurePoint>>{}),
          computersForDiveProvider(dive.id).overrideWith((ref) async => []),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: DiveDetailPage(diveId: dive.id, embedded: true)),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    FlutterError.onError = originalOnError;
  }

  testWidgets('the chart draws the whole combined dive, not the first half', (
    tester,
  ) async {
    await pumpPage(tester);

    final chart = tester.widget<DiveProfileChart>(
      find.byType(DiveProfileChart),
    );
    expect(chart.profile.length, dive.profile.length);
    expect(chart.profile.last.timestamp, secondHalf.last.timestamp);
  });

  testWidgets('carried provenance is not offered as switchable sources', (
    tester,
  ) async {
    await pumpPage(tester);

    expect(find.byType(SourceBar), findsNothing);
  });

  testWidgets('two computers recording the same minutes still get the source '
      'bar and per-source rendering', (tester) async {
    // The counterpart the gate must not catch: overlapping spans mean two
    // recordings of one dive, where drawing the union is the sawtooth of
    // issue #543.
    sources = [
      DiveDataSource(
        id: 'src-a',
        diveId: dive.id,
        computerId: 'dc-a',
        isPrimary: true,
        computerName: 'Perdix',
        importedAt: now,
        createdAt: now,
      ),
      DiveDataSource(
        id: 'src-b',
        diveId: dive.id,
        computerId: 'dc-b',
        isPrimary: false,
        computerName: 'Teric',
        importedAt: now,
        createdAt: now,
      ),
    ];
    profiles = {
      'src-a': SourceProfile(
        sourceId: 'src-a',
        computerId: 'dc-a',
        isEdited: false,
        points: [...firstHalf, ...secondHalf],
      ),
      'src-b': SourceProfile(
        sourceId: 'src-b',
        computerId: 'dc-b',
        isEdited: false,
        points: segment(6, startSeconds: 60),
      ),
    };

    await pumpPage(tester);

    expect(find.byType(SourceBar), findsOneWidget);
    final chart = tester.widget<DiveProfileChart>(
      find.byType(DiveProfileChart),
    );
    expect(chart.profile.length, profiles['src-a']!.points.length);
  });
}
