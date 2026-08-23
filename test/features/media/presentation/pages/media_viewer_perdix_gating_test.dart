import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:submersion/features/dive_log/domain/entities/dive.dart'
    as domain;
import 'package:submersion/features/dive_log/presentation/providers/dive_providers.dart';
import 'package:submersion/features/dive_log/presentation/providers/profile_analysis_provider.dart';
import 'package:submersion/features/media/domain/entities/media_item.dart';
import 'package:submersion/features/media/domain/entities/media_source_type.dart';
import 'package:submersion/features/media/presentation/pages/media_viewer_page.dart';
import 'package:submersion/features/media/presentation/widgets/perdix_overlay/perdix_face.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

import '../../../../helpers/test_database.dart';

/// Guards that the viewer starts the profile-analysis chain ONLY when the
/// Perdix overlay can actually be shown.
///
/// The build used to watch sourceProfileAnalysisProvider (and the source /
/// gas-switch / tank-pressure providers feeding it) for EVERY dive-linked
/// item, purely to construct the Perdix face resolver -- with the overlay
/// toggled off in settings, the analysis ran and its result was thrown away.
/// Opening any dive-linked photo from the Media section therefore kicked the
/// full Buhlmann cascade (recursive residual lookback included) on the UI
/// isolate: the first ingredient of the 5-30s app-wide freeze.
void main() {
  late SharedPreferences prefs;

  Future<void> setUpWithPerdixEnabled(bool enabled) async {
    await setUpTestDatabase();
    SharedPreferences.setMockInitialValues({'perdix_overlay_enabled': enabled});
    prefs = await SharedPreferences.getInstance();
  }

  tearDown(() async {
    await tearDownTestDatabase();
  });

  final media = MediaItem(
    id: 'm1',
    diveId: 'd1',
    mediaType: MediaType.photo,
    sourceType: MediaSourceType.platformGallery,
    platformAssetId: 'g1',
    takenAt: DateTime.utc(2026, 7, 1, 10),
    createdAt: DateTime.utc(2026, 7, 1),
    updatedAt: DateTime.utc(2026, 7, 1),
    enrichment: MediaEnrichment(
      id: 'e1',
      mediaId: 'm1',
      diveId: 'd1',
      elapsedSeconds: 180,
      depthMeters: 15.0,
      matchConfidence: MatchConfidence.exact,
      createdAt: DateTime.utc(2026, 7, 1),
    ),
  );

  final dive = domain.Dive(
    id: 'd1',
    dateTime: DateTime.utc(2026, 7, 1, 9, 30),
    profile: const [
      domain.DiveProfilePoint(timestamp: 0, depth: 0.0),
      domain.DiveProfilePoint(timestamp: 120, depth: 20.0),
      domain.DiveProfilePoint(timestamp: 240, depth: 5.0),
    ],
  );

  Future<void> pump(
    WidgetTester tester, {
    required void Function() onAnalysisTouched,
  }) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            diveProvider('d1').overrideWith((ref) async => dive),
            sourceProfileAnalysisProvider.overrideWith((ref, key) async {
              onAnalysisTouched();
              return null;
            }),
          ],
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: MediaViewerPage(mediaList: [media], initialMediaId: 'm1'),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
    });
  }

  testWidgets(
    'with the overlay disabled, viewing a photo never starts the analysis',
    (tester) async {
      await setUpWithPerdixEnabled(false);

      var analysisTouched = 0;
      await pump(tester, onAnalysisTouched: () => analysisTouched++);

      expect(
        analysisTouched,
        0,
        reason:
            'The Perdix face is the only consumer of the analysis in the '
            'viewer. With the overlay off, watching '
            'sourceProfileAnalysisProvider runs the whole Buhlmann cascade '
            'for a result nothing renders.',
      );
      expect(find.byType(PerdixFace), findsNothing);
      expect(
        find.byIcon(Icons.watch),
        findsOneWidget,
        reason:
            'the toggle stays offered for synced media so the user can still '
            'turn the face on from the viewer',
      );
    },
  );

  testWidgets(
    'with the overlay enabled, the analysis runs and the face shows',
    (tester) async {
      await setUpWithPerdixEnabled(true);

      var analysisTouched = 0;
      await pump(tester, onAnalysisTouched: () => analysisTouched++);

      expect(analysisTouched, greaterThan(0));
      expect(find.byType(PerdixFace), findsOneWidget);
    },
  );

  testWidgets('tapping the toggle starts the analysis on demand', (
    tester,
  ) async {
    await setUpWithPerdixEnabled(false);

    var analysisTouched = 0;
    await pump(tester, onAnalysisTouched: () => analysisTouched++);
    expect(analysisTouched, 0);

    await tester.runAsync(() async {
      await tester.tap(find.byIcon(Icons.watch));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
    });

    expect(
      analysisTouched,
      greaterThan(0),
      reason: 'enabling the overlay is what starts paying for the analysis',
    );
    expect(find.byType(PerdixFace), findsOneWidget);
  });
}
