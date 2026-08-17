import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:submersion/features/media/data/services/media_serving_recorder.dart';
import 'package:submersion/features/media/domain/entities/media_item.dart';
import 'package:submersion/features/media/domain/entities/media_provenance.dart';
import 'package:submersion/features/media/domain/entities/media_source_type.dart';
import 'package:submersion/features/media/presentation/providers/media_provenance_providers.dart';
import 'package:submersion/features/media/presentation/providers/media_serving_providers.dart';
import 'package:submersion/features/media/presentation/widgets/media_info_panel.dart';
import 'package:submersion/features/media/presentation/widgets/media_status_badge.dart';
import 'package:submersion/features/media_store/presentation/providers/media_store_providers.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';

import '../../../../helpers/l10n_test_helpers.dart';
import '../../../../helpers/mock_providers.dart';

MediaItem _item({
  MediaSourceType sourceType = MediaSourceType.platformGallery,
  bool missing = false,
  bool uploaded = false,
}) => MediaItem(
  id: 'm1',
  mediaType: MediaType.photo,
  sourceType: sourceType,
  platformAssetId: 'asset-1',
  originalFilename: 'reef.jpg',
  isOrphaned: missing,
  lastVerifiedAt: DateTime.utc(2026),
  remoteUploadedAt: uploaded ? DateTime.utc(2026, 7) : null,
  takenAt: DateTime(2026, 3, 12),
  createdAt: DateTime(2026, 3, 12),
  updatedAt: DateTime(2026, 3, 12),
);

void main() {
  late String? previousDefaultLocale;

  setUp(() {
    previousDefaultLocale = Intl.defaultLocale;
    Intl.defaultLocale = 'en_US';
  });

  tearDown(() {
    Intl.defaultLocale = previousDefaultLocale;
  });

  Future<int> pump(
    WidgetTester tester,
    MediaItem item, {
    bool attached = true,
    QueueFacts? queue,
  }) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var tileTaps = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mediaStoreAttachedProvider.overrideWith((ref) async => attached),
          mediaQueueFactsProvider.overrideWith(
            (ref, id) => Stream.value(queue),
          ),
          mediaStoreIdentityProvider.overrideWith((ref) async => null),
          currentDeviceIdProvider.overrideWith((ref) async => 'dev-a'),
          mediaServingRecorderProvider.overrideWithValue(
            MediaServingRecorder(),
          ),
          settingsProvider.overrideWith((ref) => MockSettingsNotifier()),
        ],
        child: localizedMaterialApp(
          locale: const Locale('en'),
          home: Scaffold(
            body: GestureDetector(
              onTap: () => tileTaps++,
              child: Center(child: MediaStatusBadge(item: item)),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return tileTaps;
  }

  testWidgets('a healthy backed-up item renders nothing', (tester) async {
    await pump(tester, _item(uploaded: true));

    expect(find.byKey(const Key('media-status-badge')), findsNothing);
  });

  testWidgets('a missing item renders the broken glyph', (tester) async {
    await pump(tester, _item(missing: true));

    expect(find.byKey(const Key('media-status-badge')), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
  });

  testWidgets('an unbacked item renders the cloud-off glyph', (tester) async {
    await pump(tester, _item());

    expect(find.byIcon(Icons.cloud_off), findsOneWidget);
  });

  testWidgets('a missing but backed-up item renders the cloud glyph', (
    tester,
  ) async {
    await pump(tester, _item(missing: true, uploaded: true));

    expect(find.byIcon(Icons.cloud), findsOneWidget);
  });

  testWidgets('an in-flight transfer renders the upload glyph', (tester) async {
    await pump(tester, _item(), queue: const QueueFacts(state: 'transferring'));

    expect(find.byIcon(Icons.cloud_upload), findsOneWidget);
  });

  testWidgets('an ineligible source stays silent', (tester) async {
    await pump(tester, _item(sourceType: MediaSourceType.networkUrl));

    expect(find.byKey(const Key('media-status-badge')), findsNothing);
  });

  testWidgets('the tooltip names the state', (tester) async {
    await pump(tester, _item(missing: true));

    final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
    expect(tooltip.message, 'Missing and not backed up');
  });

  // The badge sits inside a tile whose own tap opens the viewer. Aiming at
  // the badge has to explain the badge, not navigate away from it.
  testWidgets('tapping the badge opens the info panel and not the tile', (
    tester,
  ) async {
    await pump(tester, _item(missing: true));

    await tester.tap(find.byKey(const Key('media-status-badge')));
    await tester.pumpAndSettle();

    expect(find.byType(MediaInfoPanel), findsOneWidget);
  });
}
