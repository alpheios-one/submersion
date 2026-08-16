import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/dive_log/domain/entities/dive.dart';
import 'package:submersion/features/dive_log/presentation/providers/dive_repository_provider.dart';
import 'package:submersion/features/divers/presentation/providers/diver_providers.dart';
import 'package:submersion/features/media/data/services/trip_media_scanner.dart';
import 'package:submersion/features/media/domain/entities/media_library_filter.dart';
import 'package:submersion/features/media/domain/services/dive_photo_matcher.dart';
import 'package:submersion/features/media/presentation/providers/media_library_providers.dart';
import 'package:submersion/features/media/presentation/providers/media_providers.dart';

/// Suggestion for one unlinked item: the matcher verdict plus display
/// context for the confident chip.
class InboxSuggestion {
  const InboxSuggestion({required this.match, this.diveNumber});

  final TimestampMatch match;
  final int? diveNumber;
}

/// Pure suggestion computation: builds matcher bounds from [candidateDives]
/// (entryTime falling back to dateTime; exitTime falling back to
/// dateTime + effectiveRuntime, else 60 minutes) and normalizes everything
/// to wall-clock UTC so photo timestamps (stored wall-clock-as-UTC) compare
/// against dive times (local wall clock) on one basis.
Future<InboxSuggestion> computeInboxSuggestion({
  required DateTime takenAt,
  required List<Dive> candidateDives,
}) async {
  final bounds = <DiveBounds>[];
  final numbersById = <String, int?>{};
  for (final dive in candidateDives) {
    final entry = dive.entryTime ?? dive.dateTime;
    final exit =
        dive.exitTime ??
        (dive.effectiveRuntime != null
            ? dive.dateTime.add(dive.effectiveRuntime!)
            : dive.dateTime.add(const Duration(minutes: 60)));
    bounds.add(
      DiveBounds(
        diveId: dive.id,
        entryTime: TripMediaScanner.toWallClockUtc(entry),
        exitTime: TripMediaScanner.toWallClockUtc(exit),
      ),
    );
    numbersById[dive.id] = dive.diveNumber;
  }

  final match = const DivePhotoMatcher().matchTimestamp(
    takenAt: TripMediaScanner.toWallClockUtc(takenAt),
    dives: bounds,
  );
  return InboxSuggestion(
    match: match,
    diveNumber: match.diveId == null ? null : numbersById[match.diveId],
  );
}

/// Matcher verdict for one unlinked media id: candidate dives come from a
/// one-day window around the item's takenAt.
///
/// Subscribes to the DIVES tick, not a media one: the verdict is a join of
/// this item against the dives in its window, so it goes stale when the
/// candidate set moves underneath it -- a consolidation merging two dives, a
/// bulk delete, or a sync pull -- none of which write the media table. Without
/// this the inbox keeps offering a match against a dive that no longer exists.
final inboxSuggestionProvider = FutureProvider.family<InboxSuggestion, String>((
  ref,
  mediaId,
) async {
  final diveRepository = ref.watch(diveRepositoryProvider);
  ref.invalidateSelfWhen(diveRepository.watchDivesChanges());

  final item = await ref.watch(mediaByIdProvider(mediaId).future);
  if (item == null) {
    return const InboxSuggestion(
      match: TimestampMatch(kind: TimestampMatchKind.none),
    );
  }
  final takenAt = item.takenAt;
  final dives = await diveRepository.getDivesInRange(
    takenAt.subtract(const Duration(days: 1)),
    takenAt.add(const Duration(days: 1)),
    diverId: ref.read(currentDiverIdProvider),
  );
  return computeInboxSuggestion(takenAt: takenAt, candidateDives: dives);
});

/// Paged unlinked entries: the Phase 1 library notifier pinned to the
/// unlinked health filter (its media-change stream keeps the inbox live as
/// items get linked, kept, or deleted).
final unlinkedInboxProvider =
    StateNotifierProvider<MediaLibraryNotifier, MediaLibraryState>((ref) {
      final repo = ref.watch(mediaLibraryRepositoryProvider);
      final diverId = ref.watch(currentDiverIdProvider);
      return MediaLibraryNotifier(
        repo,
        diverId,
        const MediaLibraryFilter(health: MediaHealthFilter.unlinked),
      );
    });
