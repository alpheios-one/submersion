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

  /// Ids the partition should report as still needed by a dive site, i.e.
  /// kept rather than deleted. Empty by default: most media is dive-only.
  final Set<String> siteLinkedIds = {};

  /// Ids the probe should report as carrying a caption or favourite.
  final Set<String> withUserMetadata = {};

  @override
  Future<({List<String> deletable, List<String> siteLinked})>
  partitionForDiveUnlink(List<String> mediaIds) async => (
    deletable: [
      for (final id in mediaIds)
        if (!siteLinkedIds.contains(id)) id,
    ],
    siteLinked: [
      for (final id in mediaIds)
        if (siteLinkedIds.contains(id)) id,
    ],
  );

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

    // Unlinking removes the media from the library outright: the row, the
    // cloud proxies and the thumbnails. Only the ORIGINAL source file is
    // spared, and nothing on this path reads or writes its path.
    testWidgets('Unlink deletes the selection and clears it', (tester) async {
      await tester.pumpWidget(
        host([entry('a', diveId: 'd1'), entry('b', diveId: 'd1')]),
      );
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(MediaLibraryTile).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(MediaLibraryTile).at(1));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Unlink'));
      await tester.pumpAndSettle();

      expect(coordinator.deleted.toSet(), {'a', 'b'});
      expect(
        mediaRepo.unlinkedFromDive,
        isEmpty,
        reason: 'nothing here is site media, so nothing is merely detached',
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MediaLibraryView)),
      );
      expect(container.read(mediaSelectionProvider), isEmpty);
    });

    testWidgets('Unlink keeps media a dive site still needs', (tester) async {
      await tester.pumpWidget(
        host([entry('a', diveId: 'd1'), entry('b', diveId: 'd1')]),
      );
      // After host(), which mints the fakes this group asserts against.
      mediaRepo.siteLinkedIds.add('b');
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(MediaLibraryTile).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(MediaLibraryTile).at(1));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Unlink'));
      await tester.pumpAndSettle();

      expect(coordinator.deleted, ['a']);
      expect(mediaRepo.unlinkedFromDive, ['b']);
    });

    testWidgets('Unlink warns before discarding a caption or favourite', (
      tester,
    ) async {
      await tester.pumpWidget(
        host([entry('a', diveId: 'd1'), entry('b', diveId: 'd1')]),
      );
      mediaRepo.withUserMetadata.add('a');
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(MediaLibraryTile).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(MediaLibraryTile).at(1));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Unlink'));
      await tester.pumpAndSettle();

      expect(find.text('Unlink and discard details?'), findsOneWidget);
      expect(
        coordinator.deleted,
        isEmpty,
        reason: 'nothing may go before the dialog is answered',
      );

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(coordinator.deleted, isEmpty);
    });

    testWidgets('confirming the warning goes through with the unlink', (
      tester,
    ) async {
      await tester.pumpWidget(host([entry('a', diveId: 'd1')]));
      mediaRepo.withUserMetadata.add('a');
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(MediaLibraryTile).first);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Unlink'));
      await tester.pumpAndSettle();
      // The dialog's confirm reuses the bar's own "Unlink" label, so target
      // the one inside the AlertDialog rather than the bar behind it.
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Unlink'),
        ),
      );
      await tester.pumpAndSettle();

      expect(coordinator.deleted, ['a']);
    });

    testWidgets('media with nothing to lose is unlinked without a dialog', (
      tester,
    ) async {
      await tester.pumpWidget(host([entry('a', diveId: 'd1')]));
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(MediaLibraryTile).first);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Unlink'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(coordinator.deleted, ['a']);
    });

    testWidgets('Unlink from site appears only when a selected item has a '
        'site', (tester) async {
      await tester.pumpWidget(host([entry('a'), entry('b', siteId: 's1')]));
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(MediaLibraryTile).first);
      await tester.pumpAndSettle();
      expect(find.text('Unlink from site'), findsNothing);

      await tester.tap(find.byType(MediaLibraryTile).at(1));
      await tester.pumpAndSettle();
      expect(find.text('Unlink from site'), findsOneWidget);

      // Only the site-linked id is sent: unlinkFromSite latches
      // retainInLibrary, which would permanently un-sweep 'a' otherwise.
      await tester.tap(find.text('Unlink from site'));
      await tester.pumpAndSettle();
      expect(mediaRepo.unlinkedFromSite.toSet(), {'b'});
    });

    testWidgets('Unlink sends only the dive-linked ids', (tester) async {
      await tester.pumpWidget(
        host([entry('a'), entry('b', diveId: 'd1'), entry('c', siteId: 's1')]),
      );
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(MediaLibraryTile).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(MediaLibraryTile).at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(MediaLibraryTile).at(2));
      await tester.pumpAndSettle();
      expect(find.text('3 selected'), findsOneWidget);

      await tester.tap(find.text('Unlink'));
      await tester.pumpAndSettle();

      // Only the dive-linked id is acted on: the unlinked row and the
      // site-only row are none of this action's business.
      expect(coordinator.deleted.toSet(), {'b'});
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

    testWidgets('long-press enters selection mode and shows the bar', (
      tester,
    ) async {
      await tester.pumpWidget(host([entry('a'), entry('b')]));
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(MediaLibraryTile).first);
      await tester.pumpAndSettle();

      expect(find.text('1 selected'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
      expect(find.text('Share'), findsOneWidget);
    });

    testWidgets('delete confirms then calls the deletion chain and clears', (
      tester,
    ) async {
      await tester.pumpWidget(host([entry('a'), entry('b')]));
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(MediaLibraryTile).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(MediaLibraryTile).at(1));
      await tester.pumpAndSettle();
      expect(find.text('2 selected'), findsOneWidget);

      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      // Confirm dialog
      expect(find.text('Delete 2 items?'), findsOneWidget);
      await tester.tap(find.text('Delete').last);
      await tester.pumpAndSettle();

      expect(coordinator.deleted.toSet(), {'a', 'b'});
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MediaLibraryView)),
      );
      expect(container.read(mediaSelectionProvider), isEmpty);
    });

    testWidgets('tap in selection mode toggles instead of opening viewer', (
      tester,
    ) async {
      await tester.pumpWidget(host([entry('a'), entry('b')]));
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(MediaLibraryTile).first);
      await tester.pumpAndSettle();
      // Tap the already-selected tile: deselects, bar disappears.
      await tester.tap(find.byType(MediaLibraryTile).first);
      await tester.pumpAndSettle();
      expect(find.text('Delete'), findsNothing);
    });

    testWidgets('the close button leaves selection mode', (tester) async {
      await tester.pumpWidget(host([entry('a'), entry('b')]));
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(MediaLibraryTile).first);
      await tester.pumpAndSettle();
      expect(find.text('Delete'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(find.text('Delete'), findsNothing);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MediaLibraryView)),
      );
      expect(container.read(mediaSelectionProvider), isEmpty);
    });

    testWidgets('cancelling the delete confirmation deletes nothing', (
      tester,
    ) async {
      await tester.pumpWidget(host([entry('a'), entry('b')]));
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(MediaLibraryTile).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(coordinator.deleted, isEmpty);
      // Still in selection mode: cancelling the dialog is not cancelling
      // the selection.
      expect(find.text('Delete'), findsOneWidget);
    });
  });
}
