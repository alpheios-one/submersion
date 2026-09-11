import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/dive_log/presentation/providers/dive_providers.dart';
import 'package:submersion/features/nav_track/data/repositories/nav_track_repository.dart';
import 'package:submersion/features/nav_track/data/services/nav_track_match_service.dart';

/// Repository and match-service providers for [NavTrackMatchService]'s two
/// backend sweep triggers (a dive-computer download, `download_providers.dart`;
/// after sync, `sync_providers.dart`) -- mirrors `gpsTrackMatchServiceProvider`
/// in `gps_log_providers.dart`.
///
/// Deliberately kept out of
/// `lib/features/nav_track/presentation/providers/nav_track_providers.dart`,
/// which the routes-area UI work builds out separately in parallel; that file
/// can import and reuse [navTrackMatchServiceProvider] from here rather than
/// redefining it, once the two lines of work land side by side.
final navTrackRepositoryProvider = Provider<NavTrackRepository>(
  (ref) => NavTrackRepository(),
);

final navTrackMatchServiceProvider = Provider<NavTrackMatchService>(
  (ref) => NavTrackMatchService(
    routeRepository: ref.watch(navTrackRepositoryProvider),
    diveRepository: ref.watch(diveRepositoryProvider),
  ),
);
