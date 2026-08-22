import 'dart:io';

import 'package:equatable/equatable.dart';

import 'package:submersion/features/media/data/repositories/media_repository.dart';
import 'package:submersion/features/media/data/services/local_media_platform.dart';
import 'package:submersion/features/media/data/services/media_verification_sweep.dart';
import 'package:submersion/features/media/domain/entities/media_source_type.dart';

/// Aggregated counts shown in Settings → Media Sources → Local files.
///
/// Counts are derived from the persisted [MediaItem.isOrphaned] flag, which
/// is updated either at link time or by [LocalFilesDiagnosticsService.reverifyAll].
class LocalFilesDiagnostics extends Equatable {
  final int total;
  final int available;
  final int unavailable;

  const LocalFilesDiagnostics({
    required this.total,
    required this.available,
    required this.unavailable,
  });

  @override
  List<Object?> get props => [total, available, unavailable];
}

/// Diagnostics service backing the Settings → Media Sources → Local files
/// subsection. Provides cheap read-only counts and an explicit re-verify
/// action.
///
/// Read path ([diagnose]) reads the persisted [MediaItem.isOrphaned] flag
/// and never touches the filesystem. Write path ([reverifyAll]) delegates to
/// [MediaVerificationSweep], filtered to local-file rows.
class LocalFilesDiagnosticsService {
  final MediaRepository _repository;
  final MediaVerificationSweep _sweep;
  final LocalMediaPlatform _platform;

  LocalFilesDiagnosticsService({
    required MediaRepository repository,
    required MediaVerificationSweep sweep,
    required LocalMediaPlatform platform,
  }) : _repository = repository,
       _sweep = sweep,
       _platform = platform;

  /// Returns aggregated counts of local-file media items.
  ///
  /// Counts are based on the persisted `isOrphaned` flag — last set during
  /// link or by [reverifyAll]. Cheap to call repeatedly. To force a fresh
  /// check, the user invokes [reverifyAll] from the Settings UI, which
  /// updates the flag and bumps `lastVerifiedAt`.
  Future<LocalFilesDiagnostics> diagnose() async {
    final all = await _repository.getAllBySourceType(MediaSourceType.localFile);
    int available = 0;
    int unavailable = 0;
    for (final item in all) {
      if (item.isOrphaned) {
        unavailable++;
      } else {
        available++;
      }
    }
    return LocalFilesDiagnostics(
      total: all.length,
      available: available,
      unavailable: unavailable,
    );
  }

  /// Re-verifies every local-file media item, updating the orphan flag and
  /// `lastVerifiedAt`.
  ///
  /// The loop lives in [MediaVerificationSweep], which does the same work for
  /// any source type. Keeping a second copy here would mean two answers to
  /// "what does this VerifyResult mean for isOrphaned", and they would
  /// eventually disagree about the same row.
  ///
  /// This stays as the Local files subsection's own entry point and keeps
  /// returning the flipped count its snackbar shows. Per-item failures are
  /// logged and skipped inside the sweep, so one bad row cannot abort a pass.
  Future<int> reverifyAll() async {
    final outcome = await _sweep.run(sourceTypes: {MediaSourceType.localFile});
    return outcome.flipped;
  }

  /// Returns the number of persistable URI permissions Android currently
  /// holds for this app. Android caps this at 128 per app — the Settings
  /// page surfaces this as a budget gauge.
  ///
  /// Returns 0 on every non-Android platform: the platform-channel call is
  /// a no-op there, so this short-circuit avoids a meaningless mock-stub
  /// trip in tests.
  Future<int> androidUriUsage() async {
    if (!Platform.isAndroid) return 0;
    // coverage:ignore-start
    // Android-only branch; test suite runs on macOS where the early-return
    // above prevents the platform mock from being consulted regardless of
    // stub setup.
    final uris = await _platform.listPersistedUris();
    return uris.length;
    // coverage:ignore-end
  }
}
