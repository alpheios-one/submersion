import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:submersion/features/media/data/services/media_serving_recorder.dart';
import 'package:submersion/features/media/domain/entities/media_item.dart';
import 'package:submersion/features/media/domain/entities/media_provenance.dart';
import 'package:submersion/features/media/domain/entities/media_source_type.dart';
import 'package:submersion/features/media/domain/value_objects/media_source_data.dart';
import 'package:submersion/features/media/presentation/providers/media_provenance_providers.dart';
import 'package:submersion/features/media/presentation/providers/media_serving_providers.dart';
import 'package:submersion/features/media/presentation/widgets/media_info_panel.dart';
import 'package:submersion/features/media_store/presentation/providers/media_store_providers.dart';

import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';

import '../../../../helpers/l10n_test_helpers.dart';
import '../../../../helpers/mock_providers.dart';

MediaItem _item({
  MediaSourceType sourceType = MediaSourceType.platformGallery,
  String? platformAssetId = 'asset-1',
  String? localPath,
  String? originalFilename = 'reef.jpg',
  int? width = 4032,
  int? height = 3024,
  int? contentSizeBytes = 3 * 1024 * 1024,
  String? originDeviceId,
  bool isOrphaned = false,
  DateTime? lastVerifiedAt,
  DateTime? remoteUploadedAt,
  DateTime? remoteThumbUploadedAt,
}) => MediaItem(
  id: 'm1',
  mediaType: MediaType.photo,
  sourceType: sourceType,
  platformAssetId: platformAssetId,
  localPath: localPath,
  originalFilename: originalFilename,
  width: width,
  height: height,
  contentSizeBytes: contentSizeBytes,
  originDeviceId: originDeviceId,
  isOrphaned: isOrphaned,
  lastVerifiedAt: lastVerifiedAt,
  remoteUploadedAt: remoteUploadedAt,
  remoteThumbUploadedAt: remoteThumbUploadedAt,
  takenAt: DateTime(2026, 3, 12, 9, 14),
  createdAt: DateTime(2026, 3, 12),
  updatedAt: DateTime(2026, 3, 12),
);

void main() {
  late String? previousDefaultLocale;
  late MediaServingRecorder recorder;

  setUp(() {
    previousDefaultLocale = Intl.defaultLocale;
    Intl.defaultLocale = 'en_US';
    recorder = MediaServingRecorder();
  });

  tearDown(() {
    Intl.defaultLocale = previousDefaultLocale;
  });

  Future<void> pump(
    WidgetTester tester,
    MediaItem item, {
    bool attached = true,
    QueueFacts? queue,
    MediaStoreIdentity? identity,
    String thisDevice = 'device-here',
  }) async {
    // Four stacked sections overflow a default 800x600 surface, and a
    // ListView does not build what is below the fold, so the Serving block
    // would simply not exist for the finders. A taller viewport is cheaper
    // and less brittle than scrolling to each assertion.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mediaStoreAttachedProvider.overrideWith((ref) async => attached),
          mediaQueueFactsProvider.overrideWith(
            (ref, id) => Stream.value(queue),
          ),
          mediaStoreIdentityProvider.overrideWith((ref) async => identity),
          currentDeviceIdProvider.overrideWith((ref) async => thisDevice),
          mediaServingRecorderProvider.overrideWithValue(recorder),
          // UnitFormatter reads the diver's date and time preferences, and
          // the real notifier wants SharedPreferences.
          settingsProvider.overrideWith((ref) => MockSettingsNotifier()),
        ],
        child: localizedMaterialApp(
          locale: const Locale('en'),
          home: Scaffold(body: MediaInfoPanel(item: item)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('File block', () {
    testWidgets('renders filename, dimensions, size and taken date', (
      tester,
    ) async {
      await pump(tester, _item());

      expect(find.text('reef.jpg'), findsOneWidget);
      expect(find.text('4032 x 3024'), findsOneWidget);
      expect(find.text('3.0 MB'), findsOneWidget);
      // Via UnitFormatter, so a plain ASCII space rather than the U+202F
      // narrow no-break space raw intl jm formatting emits.
      expect(find.textContaining('2026'), findsWidgets);
    });

    testWidgets('renders Unknown for absent file facts', (tester) async {
      await pump(
        tester,
        _item(
          originalFilename: null,
          width: null,
          height: null,
          contentSizeBytes: null,
        ),
      );

      expect(find.text('Unknown'), findsWidgets);
    });
  });

  group('Origin block', () {
    testWidgets('renders the source label and the pointer', (tester) async {
      await pump(tester, _item());

      expect(find.text('Photo library'), findsWidgets);
      expect(find.text('asset-1'), findsOneWidget);
    });

    testWidgets('a missing row renders the missing status', (tester) async {
      await pump(tester, _item(isOrphaned: true));

      expect(find.text('Missing from this device'), findsOneWidget);
    });

    testWidgets('an unverified row renders the unchecked status', (
      tester,
    ) async {
      await pump(tester, _item());

      expect(find.text('Not checked yet'), findsOneWidget);
    });

    testWidgets('a verified row shows found plus the check date', (
      tester,
    ) async {
      await pump(tester, _item(lastVerifiedAt: DateTime(2026, 8, 1, 10)));

      expect(find.text('Found on this device'), findsOneWidget);
      expect(find.textContaining('Last checked'), findsOneWidget);
    });

    // Null originDeviceId means the source type does not track one, which is
    // true of five of the seven types. Claiming "This device" there would
    // assert a fact the app never recorded, on every gallery photo.
    testWidgets('omits the linked-on row when no device was recorded', (
      tester,
    ) async {
      await pump(tester, _item());

      expect(find.text('Linked on'), findsNothing);
    });

    testWidgets('names this device when the ids match', (tester) async {
      await pump(
        tester,
        _item(sourceType: MediaSourceType.localFile, originDeviceId: 'dev-a'),
        thisDevice: 'dev-a',
      );

      expect(find.text('This device'), findsOneWidget);
    });

    testWidgets('names another device when the ids differ', (tester) async {
      await pump(
        tester,
        _item(sourceType: MediaSourceType.localFile, originDeviceId: 'dev-b'),
        thisDevice: 'dev-a',
      );

      expect(find.text('Another device'), findsOneWidget);
    });
  });

  group('Backup block', () {
    testWidgets('an ineligible source says so instead of not backed up', (
      tester,
    ) async {
      await pump(
        tester,
        _item(sourceType: MediaSourceType.networkUrl, platformAssetId: null),
      );

      expect(
        find.text('This source is not eligible for backup'),
        findsOneWidget,
      );
      expect(find.text('Not backed up'), findsNothing);
    });

    testWidgets('no store connected renders the not-connected line', (
      tester,
    ) async {
      await pump(tester, _item(), attached: false);

      expect(find.text('No cloud store connected'), findsWidgets);
    });

    testWidgets('a thumb-only row says the original was not sent', (
      tester,
    ) async {
      await pump(
        tester,
        _item(remoteThumbUploadedAt: DateTime(2026, 7, 1)),
        identity: const MediaStoreIdentity(
          providerType: 's3',
          displayHint: 'dive-media @ minio.host',
        ),
      );

      expect(find.text('dive-media @ minio.host'), findsOneWidget);
      expect(find.text('Thumbnail only, original not sent'), findsOneWidget);
    });

    testWidgets('an uploaded row shows the upload date', (tester) async {
      await pump(tester, _item(remoteUploadedAt: DateTime(2026, 7, 1, 8)));

      expect(find.text('Original uploaded'), findsOneWidget);
      expect(find.textContaining('Uploaded'), findsWidgets);
    });

    testWidgets('a failed queue row shows its error', (tester) async {
      await pump(
        tester,
        _item(),
        queue: const QueueFacts(state: 'failed', error: 'network down'),
      );

      expect(find.text('Upload failed: network down'), findsOneWidget);
    });

    testWidgets('a settled queue row adds no line', (tester) async {
      await pump(tester, _item(), queue: const QueueFacts(state: 'done'));

      expect(find.textContaining('Uploading'), findsNothing);
      expect(find.textContaining('Waiting'), findsNothing);
    });
  });

  group('Serving block', () {
    testWidgets('an unobserved item says not loaded yet', (tester) async {
      await pump(tester, _item());

      expect(find.text('Not loaded yet'), findsOneWidget);
    });

    testWidgets('a store-cache serving reads as local cache', (tester) async {
      recorder.record(
        'm1',
        thumbnail: false,
        servedFrom: ServedFrom.storeCache,
      );
      await pump(tester, _item());

      expect(find.text('Local cache, from the cloud store'), findsOneWidget);
    });

    testWidgets('a non-original tier is named alongside the source', (
      tester,
    ) async {
      recorder.record(
        'm1',
        thumbnail: false,
        servedFrom: ServedFrom.storeNetwork,
        servedTier: ServedTier.rendition,
      );
      await pump(tester, _item());

      expect(
        find.text('Downloaded from the cloud store (Compressed version)'),
        findsOneWidget,
      );
    });

    testWidgets('a store fallback adds the fallback note', (tester) async {
      recorder.record(
        'm1',
        thumbnail: false,
        servedFrom: ServedFrom.storeNetwork,
        storeFallbackUsed: true,
      );
      await pump(tester, _item());

      expect(
        find.textContaining('original source could not be reached'),
        findsOneWidget,
      );
    });

    testWidgets('a failed resolution reads as could not be loaded', (
      tester,
    ) async {
      recorder.record(
        'm1',
        thumbnail: false,
        failure: UnavailableKind.notFound,
        storeFallbackUsed: true,
      );
      await pump(tester, _item());

      expect(find.text('Could not be loaded'), findsOneWidget);
      // The fallback note explains where bytes CAME from, so it must not
      // appear when nothing was served.
      expect(
        find.textContaining('original source could not be reached'),
        findsNothing,
      );
    });

    // The whole point of the ListenableBuilder: a tile that resolves while
    // the panel is open must update it.
    testWidgets('refreshes when the recorder records', (tester) async {
      await pump(tester, _item());
      expect(find.text('Not loaded yet'), findsOneWidget);

      recorder.record('m1', thumbnail: false, servedFrom: ServedFrom.localDisk);
      await tester.pumpAndSettle();

      expect(find.text('Not loaded yet'), findsNothing);
      expect(find.text('Local file on this device'), findsOneWidget);
    });
  });
}
