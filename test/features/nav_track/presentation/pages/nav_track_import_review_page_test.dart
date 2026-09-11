import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:submersion/features/dive_log/domain/entities/dive.dart';
import 'package:submersion/features/equipment/domain/entities/gear_link.dart';
import 'package:submersion/features/nav_track/data/services/nav_track_import_service.dart';
import 'package:submersion/features/nav_track/data/services/parsers/parsed_nav_track.dart';
import 'package:submersion/features/nav_track/domain/entities/nav_track_point.dart';
import 'package:submersion/features/nav_track/domain/nav_track_segmenter.dart';
import 'package:submersion/features/nav_track/domain/nav_track_stats.dart';
import 'package:submersion/features/nav_track/presentation/pages/nav_track_import_review_page.dart';
import 'package:submersion/features/nav_track/presentation/providers/nav_track_import_flow_providers.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

import '../../../../helpers/mock_providers.dart';

List<NavTrackPoint> _points() => const [
  NavTrackPoint(
    timestamp: 1700000000,
    north: 0,
    east: 0,
    depth: 5,
    distance: 0,
    speed: 0.3,
  ),
  NavTrackPoint(
    timestamp: 1700000600,
    north: 40,
    east: 0,
    depth: 5,
    distance: 40,
    speed: 0.3,
  ),
];

Dive _dive(String id, DateTime entry) => Dive(
  id: id,
  dateTime: entry,
  entryTime: entry,
  tanks: const [],
  profile: const [],
  gear: looseGear(const []),
  notes: '',
  photoIds: const [],
  sightings: const [],
  weights: const [],
  tags: const [],
);

NavTrackImportPreview _preview({
  List<Dive> candidateDives = const [],
  String? duplicateOfRouteId,
  List<NavTrackPoint>? points,
}) {
  final p = points ?? _points();
  return NavTrackImportPreview(
    parsed: ParsedNavTrack(points: p),
    stats: NavTrackStats.of(p),
    segmentation: NavTrackSegmenter.classify(p),
    candidateDives: candidateDives,
    duplicateOfRouteId: duplicateOfRouteId,
    sourceRef: '005.DAT.csv',
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required NavTrackImportPreview preview,
  NavTrackImportService? service,
}) async {
  final base = await getBaseOverrides();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...base,
        if (service != null)
          navTrackImportServiceProvider.overrideWithValue(service),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: NavTrackImportReviewPage(
          bytes: Uint8List(0),
          fileName: '005.DAT.csv',
          preview: preview,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the source file name and segment summary', (tester) async {
    await _pump(tester, preview: _preview());
    expect(find.text('005.DAT.csv'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('nav-track-segment-summary')),
      findsOneWidget,
    );
  });

  testWidgets('pre-selects the unique overlapping dive', (tester) async {
    final dive = _dive('d1', DateTime.utc(2025, 1, 15, 16, 16, 7));
    await _pump(tester, preview: _preview(candidateDives: [dive]));

    final radio = tester.widget<RadioListTile<String?>>(
      find.byKey(const ValueKey('nav-track-link-d1')),
    );
    expect(radio.value, 'd1');

    final group = tester.widget<RadioGroup<String?>>(
      find.byType(RadioGroup<String?>),
    );
    expect(group.groupValue, 'd1');
  });

  testWidgets('leaves the route unlinked when several dives overlap', (
    tester,
  ) async {
    final d1 = _dive('d1', DateTime.utc(2025, 1, 15, 16, 16, 7));
    final d2 = _dive('d2', DateTime.utc(2025, 1, 15, 16, 20, 0));
    await _pump(tester, preview: _preview(candidateDives: [d1, d2]));

    final group = tester.widget<RadioGroup<String?>>(
      find.byType(RadioGroup<String?>),
    );
    expect(group.groupValue, isNull);
    expect(
      find.byKey(const ValueKey('nav-track-link-unlinked')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('nav-track-link-d1')), findsOneWidget);
    expect(find.byKey(const ValueKey('nav-track-link-d2')), findsOneWidget);
  });

  testWidgets('shows no warnings for a normal, fresh import', (tester) async {
    await _pump(tester, preview: _preview());
    expect(
      find.byKey(const ValueKey('nav-track-warning-no-movement')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('nav-track-warning-duplicate')),
      findsNothing,
    );
  });

  testWidgets('warns when no movement was recorded', (tester) async {
    const still = [
      NavTrackPoint(timestamp: 1700000000, north: 0, east: 0, depth: 30),
      NavTrackPoint(timestamp: 1700000600, north: 0, east: 0, depth: 30),
    ];
    await _pump(tester, preview: _preview(points: still));
    expect(
      find.byKey(const ValueKey('nav-track-warning-no-movement')),
      findsOneWidget,
    );
  });

  testWidgets('warns about a duplicate and offers replace', (tester) async {
    await _pump(
      tester,
      preview: _preview(duplicateOfRouteId: 'existing-route'),
    );
    expect(
      find.byKey(const ValueKey('nav-track-warning-duplicate')),
      findsOneWidget,
    );
    expect(find.byType(Checkbox), findsOneWidget);
  });

  testWidgets('shows a site picker entry point defaulting to no site chosen', (
    tester,
  ) async {
    await _pump(tester, preview: _preview());
    expect(find.byKey(const ValueKey('nav-track-site-picker')), findsOneWidget);
    expect(find.text('No site chosen'), findsOneWidget);
  });

  testWidgets('shows a parse-error message when the preview future rejects', (
    tester,
  ) async {
    final base = await getBaseOverrides();
    final failingService = _FailingImportService();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...base,
          navTrackImportServiceProvider.overrideWithValue(failingService),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: NavTrackImportReviewPage(
            bytes: Uint8List(0),
            fileName: 'bad.csv',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('could not be read as a Seacraft ENC'),
      findsOneWidget,
    );
  });
}

class _FailingImportService implements NavTrackImportService {
  @override
  Future<NavTrackImportPreview> prepare(
    Uint8List bytes, {
    String? fileName,
  }) async {
    throw const NavTrackParseException(
      'bad file',
      reason: NavTrackParseReason.unreadable,
    );
  }

  @override
  Future<String> commit({
    required ParsedNavTrack parsed,
    required String sourceRef,
    Dive? dive,
    String? siteId,
    String? name,
    String? deviceName,
  }) async => throw UnimplementedError();
}
