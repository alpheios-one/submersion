import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/media/data/services/media_source_resolver_registry.dart';
import 'package:submersion/features/media/domain/entities/media_item.dart';
import 'package:submersion/features/media/domain/entities/media_library_filter.dart';
import 'package:submersion/features/media/domain/entities/media_source_type.dart';
import 'package:submersion/features/media/domain/services/media_source_resolver.dart';
import 'package:submersion/features/media/domain/value_objects/media_source_data.dart';
import 'package:submersion/features/media/domain/value_objects/media_source_metadata.dart';
import 'package:submersion/features/media/domain/value_objects/verify_result.dart';
import 'package:submersion/features/dive_log/data/repositories/dive_repository_impl.dart';
import 'package:submersion/features/dive_log/domain/entities/dive.dart';
import 'package:submersion/features/dive_log/presentation/providers/dive_repository_provider.dart';
import 'package:submersion/features/divers/presentation/providers/diver_providers.dart';
import 'package:submersion/features/media/data/repositories/media_repository.dart';
import 'package:submersion/features/media/presentation/pages/media_library_view.dart';
import 'package:submersion/features/media/presentation/providers/media_library_providers.dart';
import 'package:submersion/features/media/presentation/providers/media_providers.dart';
import 'package:submersion/features/media/presentation/providers/media_resolver_providers.dart';
import 'package:submersion/features/media/presentation/providers/media_selection_provider.dart';
import 'package:submersion/features/media/presentation/widgets/media_library_grid.dart';
import 'package:submersion/features/media_store/data/media_deletion_coordinator.dart';
import 'package:submersion/features/media_store/presentation/providers/media_store_providers.dart';
import 'package:submersion/features/settings/data/repositories/app_settings_repository.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

class _UnavailableResolver implements MediaSourceResolver {
  @override
  MediaSourceType get sourceType => MediaSourceType.localFile;
  @override
  bool canResolveOnThisDevice(MediaItem item) => true;
  @override
  Future<MediaSourceData> resolve(MediaItem item) async =>
      const UnavailableData(kind: UnavailableKind.notFound);
  @override
  Future<MediaSourceData> resolveThumbnail(
    MediaItem item, {
    required Size target,
  }) => resolve(item);
  @override
  Future<MediaSourceMetadata?> extractMetadata(MediaItem item) async => null;
  @override
  Future<VerifyResult> verify(MediaItem item) async => VerifyResult.available;
}

class _SeededLibraryNotifier extends StateNotifier<MediaLibraryState>
    implements MediaLibraryNotifier {
  _SeededLibraryNotifier(super.state);

  @override
  Future<void> loadFirstPage() async {}

  @override
  Future<void> loadMore() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSettingsRepo extends AppSettingsRepository {
  @override
  Future<String?> getRawSetting(String key) async => null;

  @override
  Future<void> setRawSetting(String key, String value) async {}
}

class _RecordingDeletionCoordinator implements MediaDeletionCoordinator {
  final List<String> deleted = [];

  @override
  Future<void> deleteMultipleMedia(List<String> ids) async {
    deleted.addAll(ids);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingMediaRepo implements MediaRepository {
  final List<String> unlinkedFromDive = [];
  final List<String> unlinkedFromSite = [];
  (List<String>, String)? reassigned;

  /// Ids the probe should report as carrying a caption or favorite.
  final Set<String> withUserMetadata = {};

  // No partition stubs: the library unlink clears every link a row has, so
  // it never asks which side still wants it. A call to one of the partitions
  // would mean the carve-out leaked back into this surface, and noSuchMethod
  // makes that a loud failure rather than a quiet empty list.

  @override
  Future<Set<String>> idsWithUserMetadata(List<String> mediaIds) async =>
      mediaIds.where(withUserMetadata.contains).toSet();

  @override
  Future<void> unlinkFromDive(List<String> mediaIds) async {
    unlinkedFromDive.addAll(mediaIds);
  }

  @override
  Future<void> unlinkFromSite(List<String> mediaIds) async {
    unlinkedFromSite.addAll(mediaIds);
  }

  @override
  Future<void> reassignMediaToDive(
    List<String> mediaIds,
    String newDiveId,
  ) async {
    reassigned = (mediaIds, newDiveId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeDiveRepo implements DiveRepository {
  @override
  Future<List<Dive>> getAllDives({String? diverId}) async => [
    Dive(id: 'dive-2', diveNumber: 2, dateTime: DateTime(2026, 6, 12)),
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FixedDiverIdNotifier extends StateNotifier<String?>
    implements CurrentDiverIdNotifier {
  _FixedDiverIdNotifier() : super('d1');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

MediaLibraryEntry entry(String id, {String? diveId, String? siteId}) =>
    MediaLibraryEntry(
      item: MediaItem(
        id: id,
        diveId: diveId,
        siteId: siteId,
        mediaType: MediaType.photo,
        sourceType: MediaSourceType.localFile,
        filePath: '/tmp/$id',
        localPath: '/tmp/$id',
        takenAt: DateTime(2026, 6, 1),
        createdAt: DateTime(2026, 6, 1),
        updatedAt: DateTime(2026, 6, 1),
      ),
    );

void main() {
  group('MediaSelectionNotifier', () {
    test('toggle adds then removes an id; clear empties', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(mediaSelectionProvider.notifier);

      notifier.toggle('a');
      expect(container.read(mediaSelectionProvider), {'a'});
      notifier.toggle('b');
      expect(container.read(mediaSelectionProvider), {'a', 'b'});
      notifier.toggle('a');
      expect(container.read(mediaSelectionProvider), {'b'});
      notifier.clear();
      expect(container.read(mediaSelectionProvider), isEmpty);
    });
  });

  group('selection UI', () {
    late _RecordingDeletionCoordinator coordinator;
    late _RecordingMediaRepo mediaRepo;

    Widget host(List<MediaLibraryEntry> entries) {
      coordinator = _RecordingDeletionCoordinator();
      mediaRepo = _RecordingMediaRepo();
      return ProviderScope(
        overrides: [
          mediaLibraryNotifierProvider.overrideWith(
            (ref) =>
                _SeededLibraryNotifier(MediaLibraryState(entries: entries)),
          ),
          appSettingsRepositoryProvider.overrideWithValue(_FakeSettingsRepo()),
          mediaDeletionCoordinatorProvider.overrideWithValue(coordinator),
          mediaRepositoryProvider.overrideWithValue(mediaRepo),
          diveRepositoryProvider.overrideWithValue(_FakeDiveRepo()),
          currentDiverIdProvider.overrideWith((ref) => _FixedDiverIdNotifier()),
          mediaSourceResolverRegistryProvider.overrideWithValue(
            MediaSourceResolverRegistry({
              MediaSourceType.localFile: _UnavailableResolver(),
            }),
          ),
        ],
        child: const MaterialApp(
          locale: Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: MediaLibraryView()),
        ),
      );
    }

    /// Taps the bar's Unlink, which always opens the confirmation.
    Future<void> tapUnlink(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('media_library_unlink')));
      await tester.pumpAndSettle();
    }

    /// The bar's button and the dialog's confirm both read "Unlink", so
    /// confirming has to be scoped to the dialog.
    Future<void> confirmUnlink(WidgetTester tester) async {
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(TextButton, 'Unlink'),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('the bar offers one destructive action, named Unlink', (
      tester,
    ) async {
      await tester.pumpWidget(
        host([entry('a', diveId: 'd1'), entry('b', siteId: 's1')]),
      );
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(MediaLibraryTile).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(MediaLibraryTile).at(1));
      await tester.pumpAndSettle();

      expect(find.text('2 selected'), findsOneWidget);
      expect(find.text('Unlink'), findsOneWidget);
      expect(find.text('Move to dive'), findsOneWidget);
      expect(find.text('Share'), findsOneWidget);
      // The per-link pair and the separate Delete are gone, and a site-linked
      // item in the selection no longer grows a second unlink button.
      expect(find.byIcon(Icons.link_off), findsOneWidget);
      expect(find.byIcon(Icons.location_off), findsNothing);
      expect(find.byIcon(Icons.delete_outline), findsNothing);
      expect(find.text('Delete'), findsNothing);
      expect(find.text('Unlink from site'), findsNothing);
    });

    // Unlinking in the library clears every link a row has: a dive or a site
    // can spare a row the other one still wants, but the library is every
    // side at once, so the row, the cloud proxies and the thumbnails all go.
    // Only the ORIGINAL source file is spared, and nothing on this path
    // reads or writes its path.
    testWidgets('confirming unlink sends the whole selection to the deletion '
        'chain and clears', (tester) async {
      await tester.pumpWidget(
        host([
          entry('a', diveId: 'd1'),
          entry('b', siteId: 's1'),
          entry('c', diveId: 'd1', siteId: 's1'),
        ]),
      );
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(MediaLibraryTile).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(MediaLibraryTile).at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(MediaLibraryTile).at(2));
      await tester.pumpAndSettle();
      expect(find.text('3 selected'), findsOneWidget);

      await tapUnlink(tester);
      expect(find.text('Unlink 3 items?'), findsOneWidget);
      expect(
        coordinator.deleted,
        isEmpty,
        reason: 'nothing may go before the dialog is answered',
      );

      await confirmUnlink(tester);

      // Every id, including the dual-linked one: no side is spared here.
      expect(coordinator.deleted.toSet(), {'a', 'b', 'c'});
      expect(
        mediaRepo.unlinkedFromDive,
        isEmpty,
        reason: 'the library detaches nothing; it removes',
      );
      expect(mediaRepo.unlinkedFromSite, isEmpty);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MediaLibraryView)),
      );
      expect(container.read(mediaSelectionProvider), isEmpty);
    });

    testWidgets('cancelling deletes nothing and keeps the selection', (
      tester,
    ) async {
      await tester.pumpWidget(
        host([entry('a', diveId: 'd1'), entry('b', diveId: 'd1')]),
      );
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(MediaLibraryTile).first);
      await tester.pumpAndSettle();
      await tapUnlink(tester);

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(coordinator.deleted, isEmpty);
      // Cancelling the dialog is not cancelling the selection.
      expect(find.text('1 selected'), findsOneWidget);
    });

    testWidgets('the confirmation names what a caption or favorite costs', (
      tester,
    ) async {
      await tester.pumpWidget(
        host([entry('a', diveId: 'd1'), entry('b', diveId: 'd1')]),
      );
      // After host(), which mints the fakes this group asserts against.
      mediaRepo.withUserMetadata.add('a');
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(MediaLibraryTile).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(MediaLibraryTile).at(1));
      await tester.pumpAndSettle();

      await tapUnlink(tester);

      // Everything else an unlink discards is derived and rebuilds from the
      // source file on a re-link. A caption and the favorite flag live only
      // in Submersion's own row, so the dialog counts them.
      expect(
        find.textContaining(
          '1 of these has a caption or favorite saved in Submersion',
        ),
        findsOneWidget,
      );

      await confirmUnlink(tester);
      expect(coordinator.deleted.toSet(), {'a', 'b'});
    });

    testWidgets('the confirmation stays quiet when nothing typed is at risk', (
      tester,
    ) async {
      await tester.pumpWidget(host([entry('a', diveId: 'd1')]));
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(MediaLibraryTile).first);
      await tester.pumpAndSettle();
      await tapUnlink(tester);

      expect(find.text('Unlink 1 items?'), findsOneWidget);
      expect(find.textContaining('caption or favorite'), findsNothing);
    });

    testWidgets('Move to dive opens the picker and reassigns', (tester) async {
      await tester.pumpWidget(host([entry('a')]));
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(MediaLibraryTile).first);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Move to dive'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('#2'));
      await tester.pumpAndSettle();

      expect(mediaRepo.reassigned?.$1, ['a']);
      expect(mediaRepo.reassigned?.$2, 'dive-2');
    });

    testWidgets('tap in selection mode toggles instead of opening viewer', (
      tester,
    ) async {
      await tester.pumpWidget(
        host([entry('a', diveId: 'd1'), entry('b', diveId: 'd1')]),
      );
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(MediaLibraryTile).first);
      await tester.pumpAndSettle();
      // Tap the already-selected tile: deselects, bar disappears.
      await tester.tap(find.byType(MediaLibraryTile).first);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('media_library_unlink')), findsNothing);
    });

    testWidgets('the close button leaves selection mode', (tester) async {
      await tester.pumpWidget(
        host([entry('a', diveId: 'd1'), entry('b', diveId: 'd1')]),
      );
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(MediaLibraryTile).first);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('media_library_unlink')),
        findsOneWidget,
      );

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('media_library_unlink')), findsNothing);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MediaLibraryView)),
      );
      expect(container.read(mediaSelectionProvider), isEmpty);
    });
  });
}
