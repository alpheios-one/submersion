import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/features/media/domain/entities/media_item.dart';
import 'package:submersion/features/media/domain/entities/media_source_type.dart';
import 'package:submersion/features/media/presentation/widgets/write_metadata_dialog.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

MediaItem _item({
  double? latitude,
  double? longitude,
  double? depthMeters = 18.3,
  double? temperatureCelsius = 21.5,
  int? elapsedSeconds = 600,
}) => MediaItem(
  id: 'm1',
  diveId: 'dive-1',
  platformAssetId: 'asset-1',
  mediaType: MediaType.photo,
  sourceType: MediaSourceType.platformGallery,
  latitude: latitude,
  longitude: longitude,
  takenAt: DateTime.utc(2026, 7, 1, 10),
  createdAt: DateTime.utc(2026, 7, 1),
  updatedAt: DateTime.utc(2026, 7, 1),
  enrichment: MediaEnrichment(
    id: 'e-m1',
    mediaId: 'm1',
    diveId: 'dive-1',
    depthMeters: depthMeters,
    temperatureCelsius: temperatureCelsius,
    elapsedSeconds: elapsedSeconds,
    matchConfidence: MatchConfidence.exact,
    createdAt: DateTime.utc(2026, 7, 1),
  ),
);

void main() {
  Future<void> pump(
    WidgetTester tester,
    MediaItem item, {
    String? siteName,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: WriteMetadataDialog(
            item: item,
            settings: const AppSettings(),
            siteName: siteName,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the GPS row appears only when the item has coordinates', (
    tester,
  ) async {
    await pump(tester, _item());
    expect(find.byIcon(Icons.location_on), findsNothing);

    await pump(tester, _item(latitude: 36.9, longitude: -25.1));
    expect(find.byIcon(Icons.location_on), findsOneWidget);
  });

  testWidgets('the site row appears only when a site name is known', (
    tester,
  ) async {
    await pump(tester, _item());
    expect(find.byIcon(Icons.place), findsNothing);

    await pump(tester, _item(), siteName: 'Dom Pedro');
    expect(find.text('Dom Pedro'), findsOneWidget);
  });

  testWidgets('an empty site name is treated as no site', (tester) async {
    await pump(tester, _item(), siteName: '');
    expect(find.byIcon(Icons.place), findsNothing);
  });

  testWidgets('no video affordance is offered (issue #1472)', (tester) async {
    // The dialog used to carry a keep-original switch for videos, whose "off"
    // position deleted the user's original. Videos no longer reach it at all.
    await pump(tester, _item(latitude: 36.9, longitude: -25.1));
    expect(find.byType(Switch), findsNothing);
    expect(find.textContaining('video'), findsNothing);
    expect(find.textContaining('Video'), findsNothing);
  });

  testWidgets('the write button is disabled when there is nothing to write', (
    tester,
  ) async {
    // hasData is depth OR temperature OR a full coordinate pair, so all
    // three have to be absent for the write to have nothing to say.
    await pump(
      tester,
      _item(depthMeters: null, temperatureCelsius: null, elapsedSeconds: null),
    );
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
  });
}
