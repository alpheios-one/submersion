import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/features/dive_log/domain/entities/dive.dart';
import 'package:submersion/features/dive_log/domain/entities/dive_data_source.dart';
import 'package:submersion/features/dive_log/presentation/pages/dive_detail_page.dart';
import 'package:submersion/features/dive_log/presentation/providers/dive_providers.dart';
import 'package:submersion/features/dive_log/presentation/widgets/dive_locations_map.dart';
import 'package:submersion/features/dive_log/presentation/widgets/site_suggestion_banner.dart';
import 'package:submersion/features/dive_sites/domain/entities/dive_site.dart';
import 'package:submersion/features/dive_sites/presentation/providers/site_suggestion_providers.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

import '../../../../helpers/mock_providers.dart';
import '../support/fake_matching_service.dart';

/// The site suggestion banner belongs above the header card, never inside it.
/// Embedded mode renders its own copy under the toolbar, so a copy in the
/// header card showed the same banner twice on the master-detail layout.
void main() {
  // Entry coordinates make the header render as the map card, which is the
  // container the banner must stay out of.
  final dive = Dive(
    id: 'dive-1',
    diveNumber: 44,
    dateTime: DateTime(2026, 1, 1),
    entryLocation: const GeoPoint(35.819674, 14.451480),
  );

  Future<void> pumpDetail(WidgetTester tester, {required bool embedded}) async {
    tester.view.devicePixelRatio = 1.0;
    // Embedded is the master-detail pane; standalone stays under the
    // master-detail breakpoint, where a root-level detail page would
    // otherwise redirect itself into the split view.
    tester.view.physicalSize = embedded
        ? const Size(1400, 2400)
        : const Size(900, 2400);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    // The header card lays a map under a gradient; overflow warnings in the
    // constrained test viewport say nothing about banner placement.
    final originalOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.toString().contains('overflowed')) return;
      originalOnError?.call(details);
    };
    addTearDown(() => FlutterError.onError = originalOnError);

    final overrides = await getBaseOverrides();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...overrides,
          diveProvider(dive.id).overrideWith((ref) async => dive),
          diveDataSourcesProvider(
            dive.id,
          ).overrideWith((ref) async => <DiveDataSource>[]),
          siteSuggestionForDiveProvider(
            dive.id,
          ).overrideWith((ref) async => suggestionFor(FakeMatchingService())),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DiveDetailPage(diveId: dive.id, embedded: embedded),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  /// The header card: the Card wrapping the location map.
  Finder headerCard() => find.ancestor(
    of: find.byType(DiveLocationsMap),
    matching: find.byType(Card),
  );

  for (final embedded in [true, false]) {
    testWidgets(
      'shows the suggestion once, outside the header card (embedded: $embedded)',
      (tester) async {
        await pumpDetail(tester, embedded: embedded);

        expect(find.byType(SiteSuggestionBanner), findsOneWidget);
        expect(
          find.descendant(
            of: headerCard(),
            matching: find.byType(SiteSuggestionBanner),
          ),
          findsNothing,
        );
        tester.takeException();
      },
    );
  }
}
