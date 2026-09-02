import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/maps/data/repositories/offline_map_repository.dart';
import 'package:submersion/features/maps/data/services/tile_cache_service.dart';
import 'package:submersion/features/maps/domain/entities/cached_region.dart';
import 'package:uuid/uuid.dart';

/// Provider for the offline map repository.
final offlineMapRepositoryProvider = Provider<OfflineMapRepository>((ref) {
  return OfflineMapRepository();
});

/// Provider for the tile cache service.
final tileCacheServiceProvider = Provider<TileCacheService>((ref) {
  return TileCacheService.instance;
});

/// Provider for all cached regions.
final cachedRegionsProvider = FutureProvider<List<CachedRegion>>((ref) async {
  final repository = ref.watch(offlineMapRepositoryProvider);
  ref.invalidateSelfWhen(repository.watchRegionsChanges());
  return repository.getAllRegions();
});

/// Provider for cache statistics.
final cacheStatsProvider = FutureProvider<CacheStats>((ref) async {
  final service = ref.watch(tileCacheServiceProvider);
  return service.getCacheStats();
});

/// The ids of the regions that own their tiles, and so can report a real size
/// and free real bytes when deleted.
///
/// A region missing from this set was downloaded before per-region stores
/// existed: its tiles are commingled in the shared offline store and cannot be
/// told apart from any other legacy region's. The UI uses this to avoid
/// claiming a size it cannot measure.
final regionStoreIdsProvider = FutureProvider<Set<String>>((ref) async {
  final service = ref.watch(tileCacheServiceProvider);
  return service.getRegionStoreIds();
});

/// State for region download progress.
class DownloadState {
  final bool isDownloading;
  final double progress;
  final int downloadedTiles;
  final int totalTiles;
  final int failedTiles;
  final double tilesPerSecond;
  final String? regionName;
  final String? error;

  const DownloadState({
    this.isDownloading = false,
    this.progress = 0.0,
    this.downloadedTiles = 0,
    this.totalTiles = 0,
    this.failedTiles = 0,
    this.tilesPerSecond = 0.0,
    this.regionName,
    this.error,
  });

  DownloadState copyWith({
    bool? isDownloading,
    double? progress,
    int? downloadedTiles,
    int? totalTiles,
    int? failedTiles,
    double? tilesPerSecond,
    String? regionName,
    String? error,
    bool clearError = false,
  }) {
    return DownloadState(
      isDownloading: isDownloading ?? this.isDownloading,
      progress: progress ?? this.progress,
      downloadedTiles: downloadedTiles ?? this.downloadedTiles,
      totalTiles: totalTiles ?? this.totalTiles,
      failedTiles: failedTiles ?? this.failedTiles,
      tilesPerSecond: tilesPerSecond ?? this.tilesPerSecond,
      regionName: regionName ?? this.regionName,
      error: clearError ? null : (error ?? this.error),
    );
  }

  /// Whether the download has completed (with or without errors).
  bool get isComplete => !isDownloading && downloadedTiles > 0;

  /// Whether the download completed with errors.
  bool get hasErrors => error != null || failedTiles > 0;
}

/// Notifier for managing region downloads.
class DownloadProgressNotifier extends StateNotifier<DownloadState> {
  final TileCacheService _cacheService;
  final OfflineMapRepository _repository;
  final Ref _ref;

  static const _uuid = Uuid();

  /// The region currently downloading, and the region whose download the
  /// diver cancelled.
  ///
  /// Cancelling and finishing both end the progress stream the same way, so
  /// the loop needs to be told which happened. Keyed by region rather than a
  /// flag so a cancellation can never be attributed to a later download.
  String? _activeRegionId;
  String? _cancelledRegionId;

  DownloadProgressNotifier(this._cacheService, this._repository, this._ref)
    : super(const DownloadState());

  /// Download tiles for a rectangular region into a store of its own.
  ///
  /// The [tileLayerOptions] should be configured with the URL template
  /// for the tile server (e.g., OpenStreetMap).
  ///
  /// The region's id is minted here, before the download, because the store
  /// that holds its tiles is named after it. Everything after that point is
  /// all-or-nothing: either the region is recorded and its store released, or
  /// the store is deleted. A store left behind would hold tiles no region
  /// could reach and nothing but "Clear all cache" could free.
  Future<void> downloadRegion({
    required String name,
    required double minLat,
    required double maxLat,
    required double minLng,
    required double maxLng,
    required int minZoom,
    required int maxZoom,
    required TileLayer tileLayerOptions,
  }) async {
    final regionId = _uuid.v4();
    _activeRegionId = regionId;
    try {
      state = state.copyWith(
        isDownloading: true,
        progress: 0.0,
        downloadedTiles: 0,
        totalTiles: 0,
        failedTiles: 0,
        tilesPerSecond: 0.0,
        regionName: name,
        clearError: true,
      );

      final stream = await _cacheService.downloadRegion(
        regionId: regionId,
        southWest: LatLng(minLat, minLng),
        northEast: LatLng(maxLat, maxLng),
        minZoom: minZoom,
        maxZoom: maxZoom,
        options: tileLayerOptions,
      );

      int downloadedTiles = 0;

      await for (final progress in stream) {
        downloadedTiles = progress.downloadedTiles;

        state = state.copyWith(
          progress: progress.percentComplete,
          downloadedTiles: progress.downloadedTiles,
          totalTiles: progress.totalTiles,
          failedTiles: progress.failedTiles,
          tilesPerSecond: progress.tilesPerSecond,
        );
      }

      if (_cancelledRegionId == regionId) {
        // A cancelled download used to keep its partial tiles and record a
        // region for them anyway. Now both go.
        await _cacheService.discardRegionDownload(regionId);
        state = const DownloadState();
        return;
      }

      // A real measurement of the region's own store, which is what per-region
      // stores buy: the size used to be tiles * 20 KiB and had never read the
      // cache.
      final sizeBytes = await _cacheService.measureRegionSize(regionId);

      // Save region to database
      await _repository.createRegion(
        id: regionId,
        name: name,
        minLat: minLat,
        maxLat: maxLat,
        minLng: minLng,
        maxLng: maxLng,
        minZoom: minZoom,
        maxZoom: maxZoom,
        tileCount: downloadedTiles,
        sizeBytes: sizeBytes,
      );

      // The store is reachable through its region now, so it no longer needs
      // protecting from the orphan sweep.
      _cacheService.finishRegionDownload(regionId);

      // Refresh the regions list and cache stats
      _ref.invalidate(cachedRegionsProvider);
      _ref.invalidate(cacheStatsProvider);
      _ref.invalidate(regionStoreIdsProvider);

      state = state.copyWith(isDownloading: false);
    } catch (e) {
      // Whatever failed, the store must not outlive the attempt.
      await _discardQuietly(regionId);
      state = state.copyWith(isDownloading: false, error: e.toString());
    }
  }

  /// Deletes a failed download's store, keeping the original failure as the
  /// error the diver sees: a cleanup that fails on the way out would otherwise
  /// replace the reason the download failed.
  Future<void> _discardQuietly(String regionId) async {
    try {
      await _cacheService.discardRegionDownload(regionId);
    } catch (_) {
      // Reported through the orphan sweep instead, which will find the store.
    }
  }

  /// Cancel an ongoing download.
  Future<void> cancelDownload() async {
    _cancelledRegionId = _activeRegionId;
    await _cacheService.cancelDownload();
    state = const DownloadState();
  }

  /// Pause an ongoing download.
  Future<void> pauseDownload() async {
    await _cacheService.pauseDownload();
  }

  /// Resume a paused download.
  void resumeDownload() {
    _cacheService.resumeDownload();
  }

  /// Check if the current download is paused.
  bool get isPaused => _cacheService.isDownloadPaused;

  /// Reset the download state (clear any errors or completed state).
  void reset() {
    state = const DownloadState();
  }
}

/// Provider for download progress notifier.
final downloadProgressProvider =
    StateNotifierProvider<DownloadProgressNotifier, DownloadState>((ref) {
      final cacheService = ref.watch(tileCacheServiceProvider);
      final repository = ref.watch(offlineMapRepositoryProvider);
      return DownloadProgressNotifier(cacheService, repository, ref);
    });

/// Provider for a specific cached region by ID.
final cachedRegionByIdProvider = FutureProvider.family<CachedRegion?, String>((
  ref,
  id,
) async {
  final repository = ref.watch(offlineMapRepositoryProvider);
  ref.invalidateSelfWhen(repository.watchRegionsChanges());
  return repository.getRegionById(id);
});

/// Provider for estimating tile count for a region.
///
/// Takes a tuple-like record of region bounds and zoom levels.
final tileCountEstimateProvider =
    FutureProvider.family<
      int,
      ({
        LatLng southWest,
        LatLng northEast,
        int minZoom,
        int maxZoom,
        TileLayer options,
      })
    >((ref, params) async {
      final service = ref.watch(tileCacheServiceProvider);
      return service.estimateTileCount(
        southWest: params.southWest,
        northEast: params.northEast,
        minZoom: params.minZoom,
        maxZoom: params.maxZoom,
        options: params.options,
      );
    });

/// Notifier for managing cached regions (CRUD operations).
class CachedRegionsNotifier
    extends StateNotifier<AsyncValue<List<CachedRegion>>> {
  final OfflineMapRepository _repository;
  final TileCacheService _cacheService;
  final Ref _ref;

  CachedRegionsNotifier(this._repository, this._cacheService, this._ref)
    : super(const AsyncValue.loading()) {
    _loadRegions();
  }

  Future<void> _loadRegions() async {
    state = const AsyncValue.loading();
    try {
      final regions = await _repository.getAllRegions();
      state = AsyncValue.data(regions);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  /// Refresh the regions list.
  Future<void> refresh() async {
    await _loadRegions();
  }

  /// Delete a cached region and its tiles.
  ///
  /// The tiles go first. If removing them fails, the region row survives, so
  /// the diver still has a handle on those bytes and can try again; the other
  /// order would leave tiles on disk that nothing in the app could see, let
  /// alone reclaim.
  ///
  /// For a region downloaded before per-region stores, removing the tiles is a
  /// no-op: they are commingled in the shared offline store with every other
  /// legacy region's and cannot be told apart. The row is still removed.
  Future<void> deleteRegion(String id) async {
    try {
      await _cacheService.deleteRegionTiles(id);

      await _repository.deleteRegion(id);

      // Reload regions
      await _loadRegions();

      // Refresh cache stats
      _ref.invalidate(cacheStatsProvider);
      _ref.invalidate(regionStoreIdsProvider);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  /// Delete region stores whose region is gone.
  ///
  /// A store outlives its region when the app dies mid-download, or when a
  /// delete removed the tiles and then failed before the row. Either way the
  /// tiles are unreachable, which is the condition this whole change exists to
  /// prevent, so the sweep runs whenever the offline maps page is opened.
  Future<void> pruneOrphanStores() async {
    final regions = await _repository.getAllRegions();
    await _cacheService.pruneOrphanRegionStores(
      knownRegionIds: regions.map((r) => r.id).toSet(),
    );
  }

  /// Update a region's last accessed timestamp.
  Future<void> touchRegion(String id) async {
    await _repository.touchRegion(id);
    await _loadRegions();
  }

  /// Clear all cached tiles and regions.
  Future<void> clearAllCache() async {
    try {
      // Clear tiles from cache service
      await _cacheService.clearCache();

      // Get all regions and delete them
      final regions = await _repository.getAllRegions();
      for (final region in regions) {
        await _repository.deleteRegion(region.id);
      }

      // Reload
      await _loadRegions();
      _ref.invalidate(cacheStatsProvider);
      _ref.invalidate(regionStoreIdsProvider);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }
}

/// Provider for the cached regions notifier.
final cachedRegionsNotifierProvider =
    StateNotifierProvider<
      CachedRegionsNotifier,
      AsyncValue<List<CachedRegion>>
    >((ref) {
      final repository = ref.watch(offlineMapRepositoryProvider);
      final cacheService = ref.watch(tileCacheServiceProvider);
      return CachedRegionsNotifier(repository, cacheService, ref);
    });
