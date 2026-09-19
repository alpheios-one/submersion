import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/core/utils/byte_format.dart';
import 'package:submersion/features/bathymetry/application/bathymetry_providers.dart';
import 'package:submersion/features/bathymetry/data/sources/swissbathy3d_source.dart';

/// Deletes every cached swissBATHY3D row: the tile cache AND this source's
/// rows in the outer, quantized [BathymetryCache] together. Deleting only
/// one of the two tables has no visible effect, since the other would keep
/// serving its already-resolved answer (see [BathymetryRepository]'s doc).
/// A no-op wherever the local cache database is not initialized.
final swissBathyClearProvider = Provider<Future<void> Function()>((ref) {
  return () async {
    final tileCache = ref.read(swissBathyTileCacheRepositoryProvider);
    final repo = ref.read(bathymetryRepositoryProvider);
    await tileCache?.clearAll();
    await repo?.clearBySource(SwissBathy3dSource.sourceId);
  };
});

/// Deletes every cached bathymetry row NOT attributed to swissBATHY3D
/// (EMODnet, NOAA DEM, GMRT, ETOPO, and any row with no source at all). A
/// no-op wherever the local cache database is not initialized.
final bathymetryOtherSourcesClearProvider = Provider<Future<void> Function()>((
  ref,
) {
  return () async {
    final repo = ref.read(bathymetryRepositoryProvider);
    await repo?.clearAllExceptSource(SwissBathy3dSource.sourceId);
  };
});

/// What the "3D Maps" reload confirmation dialog shows before the diver
/// commits: how many dive sites will be reloaded, and an approximate
/// download size. The estimate is read from data that is still cached at
/// the moment this is computed -- before the reload's own delete step runs
/// -- because averaging from an already-emptied cache would have nothing
/// left to average from.
class MapReloadEstimate {
  final int siteCount;

  /// Null when there is no cached 'ok' row anywhere to average a size from
  /// (e.g. right after a reset). The dialog then shows the site count alone
  /// rather than a fabricated number.
  final int? averageBytesPerSite;

  const MapReloadEstimate({required this.siteCount, this.averageBytesPerSite});

  int? get estimatedBytes =>
      averageBytesPerSite == null ? null : averageBytesPerSite! * siteCount;

  String? get formattedEstimatedSize {
    final bytes = estimatedBytes;
    return bytes == null ? null : formatBytes(bytes);
  }
}

final mapReloadEstimateProvider = FutureProvider<MapReloadEstimate?>((
  ref,
) async {
  final repo = ref.watch(bathymetryRepositoryProvider);
  if (repo == null) return null;
  final sites = await ref.watch(knownDiveSiteLocationsProvider.future);
  final averageBytes = await repo.averageCachedGridBytes();
  return MapReloadEstimate(
    siteCount: sites.length,
    averageBytesPerSite: averageBytes,
  );
});

/// Progress of an in-flight (or just-finished) "reload map data" run.
class MapReloadState {
  final bool isRunning;
  final int total;
  final int completed;
  final bool cancelled;
  final String? error;

  const MapReloadState({
    this.isRunning = false,
    this.total = 0,
    this.completed = 0,
    this.cancelled = false,
    this.error,
  });

  MapReloadState copyWith({
    bool? isRunning,
    int? total,
    int? completed,
    bool? cancelled,
    String? error,
    bool clearError = false,
  }) {
    return MapReloadState(
      isRunning: isRunning ?? this.isRunning,
      total: total ?? this.total,
      completed: completed ?? this.completed,
      cancelled: cancelled ?? this.cancelled,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Runs the "3D Maps" reload action: clears every cached bathymetry row
/// (both swissBATHY3D and the other providers), then walks every known dive
/// site and re-fetches its grid, one at a time.
///
/// Sequential, not parallel: the other four providers have no concurrency
/// limiter of their own, unlike swissBATHY3D's internal bounded tile pool,
/// so fetching many sites at once here would hammer them uncontrolled.
///
/// [cancel] only stops scheduling further sites; it cannot abort a site's
/// own in-flight request, since none of the five bathymetry sources
/// currently support request cancellation. The site already in flight when
/// cancel is pressed still completes (and counts) before the loop stops.
class MapReloadNotifier extends StateNotifier<MapReloadState> {
  final Ref _ref;
  bool _cancelRequested = false;

  MapReloadNotifier(this._ref) : super(const MapReloadState());

  Future<void> start() async {
    if (state.isRunning) return;
    _cancelRequested = false;
    state = const MapReloadState(isRunning: true);
    try {
      await _ref.read(swissBathyClearProvider)();
      await _ref.read(bathymetryOtherSourcesClearProvider)();

      final sites = await _ref.read(knownDiveSiteLocationsProvider.future);
      final repo = _ref.read(bathymetryRepositoryProvider);
      state = state.copyWith(total: sites.length);

      for (final site in sites) {
        if (_cancelRequested) break;
        await repo?.getGrid(site);
        state = state.copyWith(completed: state.completed + 1);
      }
    } catch (e) {
      state = state.copyWith(error: e.toString());
    } finally {
      state = state.copyWith(isRunning: false, cancelled: _cancelRequested);
    }
  }

  /// Requests that the reload stop after the site currently in flight.
  void cancel() {
    _cancelRequested = true;
  }

  void reset() {
    state = const MapReloadState();
  }
}

final mapReloadProvider =
    StateNotifierProvider<MapReloadNotifier, MapReloadState>(
      (ref) => MapReloadNotifier(ref),
    );
