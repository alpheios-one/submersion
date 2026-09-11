import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:submersion/core/constants/enums.dart';
import 'package:submersion/features/dive_log/domain/entities/dive.dart';
import 'package:submersion/features/dive_log/presentation/providers/dive_providers.dart';
import 'package:submersion/features/dive_log/presentation/widgets/pickers/site_picker_sheet.dart';
import 'package:submersion/features/dive_sites/domain/entities/dive_site.dart';
import 'package:submersion/features/dive_sites/presentation/providers/site_providers.dart';
import 'package:submersion/features/equipment/domain/entities/equipment_item.dart';
import 'package:submersion/features/equipment/presentation/providers/equipment_providers.dart';
import 'package:submersion/features/maps/presentation/providers/map_tile_providers.dart';
import 'package:submersion/features/nav_track/domain/entities/nav_track.dart';
import 'package:submersion/features/nav_track/presentation/pages/nav_track_detail_page.dart';
import 'package:submersion/features/nav_track/presentation/providers/nav_track_providers.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

import '../../../../helpers/mock_providers.dart';

NavTrack _route({
  String? diveId,
  String? equipmentId,
  String? siteId,
  double? anchorLatitude,
  double? anchorLongitude,
}) => NavTrack(
  id: 'r1',
  diveId: diveId,
  equipmentId: equipmentId,
  siteId: siteId,
  linkMode: diveId == null ? null : NavTrackLinkMode.auto,
  source: NavTrackSource.seacraftEnc,
  sourceRef: 'r1.csv',
  startTime: 1755856800000,
  endTime: 1755860400000,
  pointCount: 0,
  anchorLatitude: anchorLatitude,
  anchorLongitude: anchorLongitude,
  createdAt: DateTime(2026, 8, 22),
  updatedAt: DateTime(2026, 8, 22),
);

Future<void> _pump(
  WidgetTester tester, {
  required NavTrack route,
  Dive? linkedDive,
  EquipmentItem? equipment,
  DiveSite? site,
}) async {
  final overrides = await getBaseOverrides();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...overrides,
        navTrackByIdProvider(route.id).overrideWith((ref) async => route),
        if (linkedDive != null)
          diveProvider(linkedDive.id).overrideWith((ref) async => linkedDive),
        if (equipment != null)
          equipmentItemProvider(
            equipment.id,
          ).overrideWith((ref) async => equipment),
        if (site != null)
          siteProvider(site.id).overrideWith((ref) async => site),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: NavTrackDetailPage(trackId: route.id),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows "No dive linked" for an unlinked route', (tester) async {
    await _pump(tester, route: _route());

    expect(find.byKey(const ValueKey('nav-track-no-dive')), findsOneWidget);
    expect(find.text('No dive linked'), findsOneWidget);
    expect(find.text('Choose dive'), findsOneWidget);
  });

  testWidgets('shows the linked dive for a linked route', (tester) async {
    final dive = Dive(
      id: 'dive-1',
      diveNumber: 412,
      dateTime: DateTime(2026, 8, 22, 10, 8),
    );
    await _pump(
      tester,
      route: _route(diveId: 'dive-1'),
      linkedDive: dive,
    );

    expect(find.byKey(const ValueKey('nav-track-linked-dive')), findsOneWidget);
    expect(find.textContaining('#412'), findsOneWidget);
  });

  testWidgets('shows the no-correction sentence when nothing was aligned', (
    tester,
  ) async {
    await _pump(tester, route: _route());

    expect(find.text('No correction applied yet.'), findsOneWidget);
  });

  testWidgets('shows the linked equipment name when equipmentId is set', (
    tester,
  ) async {
    const scooter = EquipmentItem(
      id: 'eq1',
      name: 'Test Scooter',
      type: EquipmentType.dpv,
    );
    await _pump(
      tester,
      route: _route(equipmentId: 'eq1'),
      equipment: scooter,
    );

    expect(find.text('Equipment: Test Scooter'), findsOneWidget);
  });

  testWidgets('shows no equipment line when equipmentId is not set', (
    tester,
  ) async {
    await _pump(tester, route: _route());

    expect(find.textContaining('Equipment:'), findsNothing);
  });

  testWidgets(
    'the inline map preview renders a TileLayer with the app\'s tile URL '
    '(item 3)',
    (tester) async {
      await _pump(
        tester,
        route: _route(anchorLatitude: 47.1, anchorLongitude: 8.3),
      );

      final tileLayer = tester.widget<TileLayer>(find.byType(TileLayer));
      final container = ProviderScope.containerOf(
        tester.element(find.byType(NavTrackDetailPage)),
      );
      expect(tileLayer.urlTemplate, container.read(mapTileUrlProvider));
    },
  );

  group('the site row (item 4)', () {
    testWidgets(
      'shows a "no site" placeholder and "Choose site" when unset, and no '
      'longer offers "Change site" from the overflow menu',
      (tester) async {
        await _pump(tester, route: _route());

        expect(
          find.byKey(const ValueKey('nav-track-site-row')),
          findsOneWidget,
        );
        expect(find.text('No site'), findsOneWidget);
        expect(find.text('Choose site'), findsOneWidget);

        await tester.tap(find.byType(PopupMenuButton<String>));
        await tester.pumpAndSettle();
        expect(find.text('Change site'), findsNothing);
      },
    );

    testWidgets('shows the site name and "Change site" when a site is set', (
      tester,
    ) async {
      const site = DiveSite(
        id: 'site-1',
        name: 'Test Site',
        location: GeoPoint(47.1, 8.3),
      );
      await _pump(
        tester,
        route: _route(siteId: 'site-1'),
        site: site,
      );

      expect(find.byKey(const ValueKey('nav-track-site-row')), findsOneWidget);
      expect(find.text('Test Site'), findsOneWidget);
      expect(find.text('Change site'), findsOneWidget);
    });

    testWidgets('tapping the action opens the site picker', (tester) async {
      await _pump(tester, route: _route());

      await tester.tap(find.byKey(const ValueKey('nav-track-change-site')));
      await tester.pumpAndSettle();

      expect(find.byType(SitePickerSheet), findsOneWidget);
    });
  });

  group('navTrackAnchorShouldFollowSiteChange (item 5)', () {
    test('the anchor follows the new site when it was never set', () {
      expect(
        navTrackAnchorShouldFollowSiteChange(null, const GeoPoint(47.1, 8.3)),
        isTrue,
      );
    });

    test('the anchor follows the new site when it still equals the old '
        'site\'s pin (the diver never moved the start point)', () {
      const oldSiteLocation = GeoPoint(47.1, 8.3);
      expect(
        navTrackAnchorShouldFollowSiteChange(oldSiteLocation, oldSiteLocation),
        isTrue,
      );
    });

    test('the anchor stays when the diver already moved it away from the old '
        'site\'s pin', () {
      const oldSiteLocation = GeoPoint(47.1, 8.3);
      const movedAnchor = GeoPoint(47.2, 8.4);
      expect(
        navTrackAnchorShouldFollowSiteChange(movedAnchor, oldSiteLocation),
        isFalse,
      );
    });
  });
}
