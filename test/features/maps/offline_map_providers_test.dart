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
    final error = downloadError;
    if (error != null) throw error;
    if (progress.isClosed) {
      progress = StreamController<TileDownloadProgress>();
    }
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

  @override
  Future<void> pruneOrphanRegionStores({
    required Set<String> knownRegionIds,
  }) async {
    calls.add('prune:${knownRegionIds.join(",")}');
  }

  @override
  Future<void> cancelDownload() async {
    calls.add('cancel');
    await progress.close();
  }

  @override
  Future<void> clearCache() async {
    calls.add('clearCache');
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
  });
}
