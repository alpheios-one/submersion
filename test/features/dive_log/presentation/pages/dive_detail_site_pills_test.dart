import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:submersion/features/dive_log/domain/entities/dive.dart';
import 'package:submersion/features/dive_log/domain/entities/dive_data_source.dart';
import 'package:submersion/features/dive_log/presentation/pages/dive_detail_page.dart';
import 'package:submersion/features/dive_log/presentation/providers/dive_providers.dart';
import 'package:submersion/features/dive_sites/domain/entities/dive_site.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

import '../../../../helpers/mock_providers.dart';

void main() {
  // A dive whose site has coordinates, so DiveDetailPage renders the
  // location card and its Map / 3D deep-link pills.
  const site = DiveSite(
    id: 'site-1',
    name: 'Blue Hole',
    location: GeoPoint(12.3, 45.6),
  );
  final dive = Dive(
    id: 'dive-1',
    diveNumber: 1,
    dateTime: DateTime(2023, 1, 1),
    site: site,
  );

  Future<String?> pumpAndTapPill(
    WidgetTester tester, {
    required String pillText,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final overrides = await getBaseOverrides();

    String? lastLocation;
    final router = GoRouter(
      initialLocation: '/test',
      redirect: (context, state) {
        lastLocation = state.uri.toString();
        return null;
      },
      routes: [
        GoRoute(
          path: '/test',
          builder: (context, state) =>
              DiveDetailPage(diveId: dive.id, embedded: true),
        ),
        GoRoute(
          path: '/sites/map',
          builder: (context, state) =>
              const Scaffold(body: Text('MAP_STUB_PAGE')),
        ),
      ],
    );

    // The location card lays a FlutterMap under a gradient; overflow warnings
    // in the constrained test viewport are irrelevant to this test.
    final originalOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.toString().contains('overflowed')) return;
      originalOnError?.call(details);
    };

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...overrides,
          diveProvider(dive.id).overrideWith((ref) async => dive),
          diveDataSourcesProvider(
            dive.id,
          ).overrideWith((ref) async => <DiveDataSource>[]),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // The pills sit under the card's gradient; invoke the InkWell directly
    // rather than fighting hit testing in the constrained viewport.
    final pill = find.ancestor(
      of: find.text(pillText),
      matching: find.byType(InkWell),
    );
    tester.widget<InkWell>(pill.first).onTap!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    tester.takeException();

    FlutterError.onError = originalOnError;
    return lastLocation;
  }

  testWidgets('Map pill deep-links to the unified map', (tester) async {
    final location = await pumpAndTapPill(tester, pillText: 'Map');
    expect(location, '/sites/map?site=site-1');
    expect(find.text('MAP_STUB_PAGE'), findsOneWidget);
  });

  testWidgets('3D pill deep-links to the unified map in 3D', (tester) async {
    final location = await pumpAndTapPill(tester, pillText: '3D');
    expect(location, contains('/sites/map?site=site-1'));
    expect(location, contains('scape=3d'));
    expect(find.text('MAP_STUB_PAGE'), findsOneWidget);
  });
}
