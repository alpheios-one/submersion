import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/dive_log/domain/entities/dive_data_source.dart';
import 'package:submersion/features/dive_log/domain/entities/source_profile.dart';
import 'package:submersion/features/dive_log/presentation/providers/dive_providers.dart';

/// The data source whose data drives the dive detail page (chart, stat
/// chips, deco and tissue cards). Null means "the primary source" so the
/// page needs no async initialization. View state only: switching the
/// active source never writes isPrimary; that changes solely via the
/// explicit "Set as primary" action. autoDispose: leaving the dive resets
/// the selection, so reopening a dive always starts at the primary source.
final activeDiveSourceProvider = StateProvider.autoDispose
    .family<String?, String>((ref, diveId) => null);

/// Source IDs currently overlaid on the profile chart for comparison.
/// The active source is never a member; activating a source removes it.
final overlaySourcesProvider = StateProvider.autoDispose
    .family<Set<String>, String>((ref, diveId) => const {});

/// The series the profile chart draws for [diveId] on a multi-source dive:
/// the active source's own profile, or the primary's when nothing is
/// selected (or the selection went stale after a split). Null on a
/// single-source dive and while the sources are still loading, so callers
/// fall back to `dive.profile`, which is identical to the primary's series
/// there.
///
/// This is the one rule behind every chart surface (detail page, fullscreen,
/// dive-list panel). `dive.profile` is the merged union of EVERY source's
/// samples interleaved by timestamp; on a consolidated dive that union
/// alternates between two computers' readings sample by sample, so any
/// surface that draws it renders a full-band sawtooth (#543).
final activeSourceProfileProvider = Provider.autoDispose
    .family<SourceProfile?, String>((ref, diveId) {
      final dataSources =
          ref.watch(diveDataSourcesProvider(diveId)).valueOrNull ??
          const <DiveDataSource>[];
      if (dataSources.length < 2) return null;
      final sourceProfiles =
          ref.watch(sourceProfilesProvider(diveId)).valueOrNull ??
          const <String, SourceProfile>{};
      final activeSourceId = ref.watch(activeDiveSourceProvider(diveId));
      final primary =
          dataSources.where((s) => s.isPrimary).firstOrNull ??
          dataSources.first;
      final active = activeSourceId == null
          ? primary
          : dataSources.where((s) => s.id == activeSourceId).firstOrNull ??
                primary;
      return sourceProfiles[active.id];
    });
