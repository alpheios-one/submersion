import 'dart:async';

import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:submersion/features/maps/data/repositories/offline_map_repository.dart';
import 'package:submersion/features/maps/data/services/tile_cache_service.dart';
import 'package:submersion/features/maps/presentation/providers/offline_map_providers.dart';

import '../../helpers/test_database.dart';

/// Records every tile-store call the providers make, so the orchestration that
/// issue #1403 is about (tiles removed before the row, a cancelled download
/// leaving neither tiles nor a row) can be asserted without an ObjectBox
/// backend, which `flutter test` has no way to stand up.
class _FakeTileCache implements TileCacheService {
  final calls = <String>[];

  /// The controller backing the most recent download. Recreated per call, so
  /// a test can run a second download after cancelling the first.
  StreamController<TileDownloadProgress> progress =
      StreamController<TileDownloadProgress>();

  int measuredBytes = 0;
  Object? deleteTilesError;
  Object? downloadError;
  Object? clearCacheError;

  /// When set, [downloadRegion] waits on this before handing back its stream,
  /// standing in for the store creation the real service awaits there.
  Completer<void>? setupGate;

  /// Whether a download instance exists yet. The real service has nothing to
  /// cancel until `startForeground` has run, and cancelling before that is a
  /// no-op there too; without modelling that, a test cannot tell an early
  /// cancellation from a late one.
  bool downloadStarted = false;
  Set<String> regionStoreIds = {};

  @override
  Future<Stream<TileDownloadProgress>> downloadRegion({
    required String regionId,
    required LatLng southWest,
    required LatLng northEast,
    required int minZoom,
    required int maxZoom,
    required TileLayer options,
    int parallelThreads = 5,
    bool skipExistingTiles = true,
  }) async {
    calls.add('download:$regionId');
    final gate = setupGate;
    if (gate != null) await gate.future;
    final error = downloadError;
    if (error != null) throw error;
    if (progress.isClosed) {
      progress = StreamController<TileDownloadProgress>();
    }
    downloadStarted = true;
    return progress.stream;
  }

  @override
  Future<int> measureRegionSize(String regionId) async {
    calls.add('measure:$regionId');
    return measuredBytes;
  }

  @override
  Future<void> deleteRegionTiles(String regionId) async {
    calls.add('deleteTiles:$regionId');
    final error = deleteTilesError;
    if (error != null) throw error;
  }

  @override
  Future<void> discardRegionDownload(String regionId) async {
    calls.add('discard:$regionId');
  }

  @override
  void finishRegionDownload(String regionId) {
    calls.add('finish:$regionId');
  }

  @override
  Future<Set<String>> getRegionStoreIds() async {
    calls.add('storeIds');
    return regionStoreIds;
  }

  int prunedStores = 0;

  @override
  Future<int> pruneOrphanRegionStores({
    required Set<String> knownRegionIds,
  }) async {
    calls.add('prune:${knownRegionIds.join(",")}');
    return prunedStores;
  }

  @override
  Future<void> cancelDownload() async {
    calls.add('cancel');
    // Nothing to cancel until the download has started, exactly as in the
    // service, where the instance id is not assigned until then.
    if (!downloadStarted) return;
    // Not awaited: close() on a controller nobody listened to completes only
    // once a subscriber drains it.
    if (!progress.isClosed) unawaited(progress.close());
  }

  @override
  Future<void> clearCache() async {
    calls.add('clearCache');
    final error = clearCacheError;
    if (error != null) throw error;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} should not be called');
}

void main() {
  late _FakeTileCache cache;
  late OfflineMapRepository repository;
  late ProviderContainer container;

  setUp(() async {
    await setUpTestDatabase();
    cache = _FakeTileCache();
    repository = OfflineMapRepository();
    container = ProviderContainer(
      overrides: [tileCacheServiceProvider.overrideWithValue(cache)],
    );
  });

  tearDown(() async {
    container.dispose();
    // Not awaited: close() on a controller nobody listened to completes only
    // once a subscriber drains it, so awaiting it here hangs the test.
    if (!cache.progress.isClosed) unawaited(cache.progress.close());
    await tearDownTestDatabase();
  });

  final tileLayer = TileLayer(
    urlTemplate: 'https://tile.example/{z}/{x}/{y}.png',
  );

  Future<void> downloadOneRegion({int tiles = 40}) async {
    final notifier = container.read(downloadProgressProvider.notifier);
    final done = notifier.downloadRegion(
      name: 'Cozumel',
      minLat: 20,
      maxLat: 21,
      minLng: -87,
      maxLng: -86,
      minZoom: 8,
      maxZoom: 12,
      tileLayerOptions: tileLayer,
    );
    await Future<void>.delayed(Duration.zero);
    cache.progress.add(
      TileDownloadProgress(
        downloadedTiles: tiles,
        totalTiles: tiles,
        failedTiles: 0,
        tilesPerSecond: 10,
        isComplete: true,
      ),
    );
    await cache.progress.close();
    await done;
  }

  group('download', () {
    test('records the measured size, not a per-tile constant', () async {
      cache.measuredBytes = 3 * 1024 * 1024;

      await downloadOneRegion(tiles: 40);

      final regions = await repository.getAllRegions();
      expect(regions, hasLength(1));
      // The old code stored tiles * 20 KiB, which for 40 tiles would be
      // 800 KiB and would be wrong for essentially every real region.
      expect(regions.single.sizeBytes, 3 * 1024 * 1024);
      expect(regions.single.tileCount, 40);
    });

    test('downloads into a store named for the region it creates', () async {
      await downloadOneRegion();

      final regions = await repository.getAllRegions();
      expect(cache.calls, contains('download:${regions.single.id}'));
      expect(
        cache.calls,
        contains('finish:${regions.single.id}'),
        reason: 'the store is only unprotected once its row exists',
      );
    });

    test('a cancelled download leaves neither tiles nor a region', () async {
      final notifier = container.read(downloadProgressProvider.notifier);
      final done = notifier.downloadRegion(
        name: 'Cozumel',
        minLat: 20,
        maxLat: 21,
        minLng: -87,
        maxLng: -86,
        minZoom: 8,
        maxZoom: 12,
        tileLayerOptions: tileLayer,
      );
      await Future<void>.delayed(Duration.zero);
      cache.progress.add(
        const TileDownloadProgress(
          downloadedTiles: 5,
          totalTiles: 100,
          failedTiles: 0,
          tilesPerSecond: 5,
          isComplete: false,
        ),
      );
      await notifier.cancelDownload();
      await done;

      expect(await repository.getAllRegions(), isEmpty);
      expect(
        cache.calls.where((c) => c.startsWith('discard:')),
        hasLength(1),
        reason: 'the partial store must go, or its tiles are unreachable',
      );
      expect(cache.calls.where((c) => c.startsWith('measure:')), isEmpty);
    });

    test('cancelling one download does not cancel the next', () async {
      // The cancellation is keyed to the region it was aimed at. If it were a
      // bare flag, or the id outlived its download, the next download would
      // discard its own tiles and record nothing.
      final notifier = container.read(downloadProgressProvider.notifier);
      final first = notifier.downloadRegion(
        name: 'Cozumel',
        minLat: 20,
        maxLat: 21,
        minLng: -87,
        maxLng: -86,
        minZoom: 8,
        maxZoom: 12,
        tileLayerOptions: tileLayer,
      );
      await Future<void>.delayed(Duration.zero);
      await notifier.cancelDownload();
      await first;

      expect(await repository.getAllRegions(), isEmpty);

      cache.measuredBytes = 5 * 1024 * 1024;
      await downloadOneRegion(tiles: 12);

      final regions = await repository.getAllRegions();
      expect(regions, hasLength(1));
      expect(regions.single.sizeBytes, 5 * 1024 * 1024);
      expect(
        cache.calls.where((c) => c.startsWith('discard:')),
        hasLength(1),
        reason: 'only the cancelled download discards its store',
      );
    });

    test(
      'cancelling during setup stops the download then, not at the end',
      () async {
        // The progress card is up while the store is still being created, so
        // cancel is reachable before there is any download instance to cancel.
        // Left unhandled, the whole region downloads and is then discarded.
        cache.setupGate = Completer<void>();

        final notifier = container.read(downloadProgressProvider.notifier);
        final done = notifier.downloadRegion(
          name: 'Cozumel',
          minLat: 20,
          maxLat: 21,
          minLng: -87,
          maxLng: -86,
          minZoom: 8,
          maxZoom: 12,
          tileLayerOptions: tileLayer,
        );
        await Future<void>.delayed(Duration.zero);

        // Nothing has started, so this reaches the service as a no-op and the
        // progress stream stays open, exactly as it would in the app.
        await notifier.cancelDownload();
        cache.setupGate!.complete();
        await Future<void>.delayed(Duration.zero);

        // Asserted while the stream is still open, which is the only moment
        // the two behaviours differ: without the check the loop is subscribed
        // here and the region downloads in full before being thrown away.
        expect(
          cache.progress.hasListener,
          isFalse,
          reason: 'the cancelled download is abandoned, not drained to the end',
        );

        unawaited(cache.progress.close());
        await done;

        expect(await repository.getAllRegions(), isEmpty);
        expect(
          cache.calls.where((c) => c.startsWith('discard:')),
          hasLength(1),
        );
        expect(
          cache.calls.where((c) => c.startsWith('measure:')),
          isEmpty,
          reason: 'nothing was kept, so nothing should have been measured',
        );
      },
    );

    test('a download that supersedes another discards it', () async {
      // Starting a second region cancels the first inside the service. Without
      // the first being marked cancelled, its loop would end and it would
      // record a region for whatever few tiles it had, which is the phantom
      // region this branch removed from the cancel path.
      final notifier = container.read(downloadProgressProvider.notifier);
      final first = notifier.downloadRegion(
        name: 'Cozumel',
        minLat: 20,
        maxLat: 21,
        minLng: -87,
        maxLng: -86,
        minZoom: 8,
        maxZoom: 12,
        tileLayerOptions: tileLayer,
      );
      await Future<void>.delayed(Duration.zero);
      cache.progress.add(
        const TileDownloadProgress(
          downloadedTiles: 3,
          totalTiles: 500,
          failedTiles: 0,
          tilesPerSecond: 3,
          isComplete: false,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      // The service closes the first download's stream when the next starts.
      unawaited(cache.progress.close());
      cache.measuredBytes = 2 * 1024 * 1024;
      await downloadOneRegion(tiles: 25);
      await first;

      final regions = await repository.getAllRegions();
      expect(
        regions,
        hasLength(1),
        reason: 'only the download that finished is a region',
      );
      expect(regions.single.tileCount, 25);
      expect(cache.calls.where((c) => c.startsWith('discard:')), hasLength(1));
    });

    test('a failed download leaves no store behind', () async {
      // The store is created before the first tile arrives, so a download that
      // throws anywhere after that would strand it holding tiles no region
      // could reach.
      cache.downloadError = StateError('tile server unreachable');

      final notifier = container.read(downloadProgressProvider.notifier);
      await notifier.downloadRegion(
        name: 'Cozumel',
        minLat: 20,
        maxLat: 21,
        minLng: -87,
        maxLng: -86,
        minZoom: 8,
        maxZoom: 12,
        tileLayerOptions: tileLayer,
      );

      expect(await repository.getAllRegions(), isEmpty);
      expect(cache.calls.where((c) => c.startsWith('discard:')), hasLength(1));
      expect(
        container.read(downloadProgressProvider).error,
        contains('tile server unreachable'),
        reason:
            'the diver must see why the download failed, not why the '
            'cleanup after it did',
      );
    });
  });

  group('clear all', () {
    test('drops every region row and all of their tiles', () async {
      for (final id in ['a', 'b']) {
        await repository.createRegion(
          id: id,
          name: 'Region $id',
          minLat: 20,
          maxLat: 21,
          minLng: -87,
          maxLng: -86,
          minZoom: 8,
          maxZoom: 12,
          tileCount: 10,
          sizeBytes: 1024,
        );
      }

      await container
          .read(cachedRegionsNotifierProvider.notifier)
          .clearAllCache();

      expect(cache.calls, contains('clearCache'));
      expect(await repository.getAllRegions(), isEmpty);
    });
  });

  group('clear all failure', () {
    test('keeps the rows when the tiles could not all be cleared', () async {
      // Same invariant as a single delete: rows are the only handle on the
      // bytes, so they outlive a clear that did not finish.
      await repository.createRegion(
        id: 'a',
        name: 'Cozumel',
        minLat: 20,
        maxLat: 21,
        minLng: -87,
        maxLng: -86,
        minZoom: 8,
        maxZoom: 12,
        tileCount: 10,
        sizeBytes: 1024,
      );
      cache.clearCacheError = StateError('one store is locked');

      await container
          .read(cachedRegionsNotifierProvider.notifier)
          .clearAllCache();

      expect(await repository.getAllRegions(), hasLength(1));
    });
  });

  group('delete', () {
    Future<String> seedRegion({String id = 'region-1'}) async {
      await repository.createRegion(
        id: id,
        name: 'Cozumel',
        minLat: 20,
        maxLat: 21,
        minLng: -87,
        maxLng: -86,
        minZoom: 8,
        maxZoom: 12,
        tileCount: 100,
        sizeBytes: 2048,
      );
      return id;
    }

    test('removes the tiles before the row', () async {
      final id = await seedRegion();

      await container
          .read(cachedRegionsNotifierProvider.notifier)
          .deleteRegion(id);

      expect(cache.calls, contains('deleteTiles:$id'));
      expect(await repository.getRegionById(id), isNull);
    });

    test('keeps the row when the tiles could not be removed', () async {
      // Losing the row while the bytes survive is the exact failure this
      // issue is about: the tiles become unreachable and invisible.
      final id = await seedRegion();
      cache.deleteTilesError = StateError('store locked');

      await container
          .read(cachedRegionsNotifierProvider.notifier)
          .deleteRegion(id);

      expect(await repository.getRegionById(id), isNotNull);
    });
  });

  group('orphan stores', () {
    test('the sweep is told exactly which regions still exist', () async {
      await repository.createRegion(
        id: 'kept',
        name: 'Cozumel',
        minLat: 20,
        maxLat: 21,
        minLng: -87,
        maxLng: -86,
        minZoom: 8,
        maxZoom: 12,
        tileCount: 10,
        sizeBytes: 1024,
      );

      await container
          .read(cachedRegionsNotifierProvider.notifier)
          .pruneOrphanStores();

      expect(cache.calls, contains('prune:kept'));
    });

    test('the sweep reports what it reclaimed', () async {
      // The caller needs this: storage totals already on screen were measured
      // before the sweep deleted anything.
      cache.prunedStores = 3;

      final reclaimed = await container
          .read(cachedRegionsNotifierProvider.notifier)
          .pruneOrphanStores();

      expect(reclaimed, 3);
    });
  });
}
