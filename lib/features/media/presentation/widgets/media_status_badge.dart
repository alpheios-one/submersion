import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:submersion/features/media/domain/entities/media_item.dart';
import 'package:submersion/features/media/domain/entities/media_provenance.dart';
import 'package:submersion/features/media/domain/entities/media_status.dart';
import 'package:submersion/features/media/domain/services/media_displayed_source.dart';
import 'package:submersion/features/media/domain/value_objects/media_source_data.dart';
import 'package:submersion/features/media/presentation/providers/media_provenance_providers.dart';
import 'package:submersion/features/media/presentation/providers/media_serving_providers.dart';
import 'package:submersion/features/media/presentation/widgets/media_info_sheet.dart';
import 'package:submersion/features/settings/presentation/providers/media_badge_settings_provider.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// One glyph per grid tile: what is wrong with this item, or failing that,
/// where its bytes came from.
///
/// Health wins. An item with a problem or an in-flight transfer shows that
/// state in saturated colour; everything else shows a subdued provenance chip
/// (see [_ProvenanceBadge]), which the diver can switch off entirely.
///
/// This is a deliberate reversal of the original quiet-on-success design.
/// Rendering nothing for a healthy item made a working badge layer
/// indistinguishable from a broken one: on a library with no cloud store and
/// no missing files, EVERY item was healthy, so the feature was invisible and
/// unverifiable. Saying where each item is served from means the common case
/// carries information instead of carrying nothing.
///
/// Deriving from [mediaProvenanceProvider] rather than a second per-item
/// queue watch halves the stream subscriptions a scrolling grid opens.
class MediaStatusBadge extends ConsumerWidget {
  const MediaStatusBadge({super.key, required this.item});

  final MediaItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = mediaStatusFor(ref.watch(mediaProvenanceProvider(item)));
    if (status == MediaStatus.none) return _ProvenanceBadge(item: item);

    final scheme = Theme.of(context).colorScheme;
    final (icon, background) = switch (status) {
      MediaStatus.broken => (Icons.error_outline, scheme.errorContainer),
      MediaStatus.transferFailed => (Icons.cloud_off, scheme.errorContainer),
      MediaStatus.transferring => (Icons.cloud_upload, scheme.primaryContainer),
      MediaStatus.queued => (Icons.schedule, scheme.surfaceContainerHighest),
      MediaStatus.cloudOnly => (Icons.cloud, scheme.surfaceContainerHighest),
      MediaStatus.notBackedUp => (
        Icons.cloud_off,
        scheme.surfaceContainerHighest,
      ),
      MediaStatus.none => (Icons.circle, scheme.surface),
    };

    return Tooltip(
      message: mediaStatusLabel(context.l10n, status),
      // Opaque so the badge claims the tap rather than letting it fall
      // through to the tile, which would open the viewer instead of
      // explaining the badge the user just aimed at.
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => showMediaInfoSheet(context, item),
        child: CircleAvatar(
          key: const Key('media-status-badge'),
          radius: 10,
          backgroundColor: background.withValues(alpha: 0.9),
          child: Icon(icon, size: 13),
        ),
      ),
    );
  }
}

/// Where this item's bytes came from, for a healthy item.
///
/// Deliberately quieter than the health badge above it: a translucent chip
/// with a white glyph, matching the video and document markers already on the
/// tile, so a grid of healthy photos still reads as photos while the
/// saturated health colours stay reserved for things that need attention.
///
/// Listens to [mediaServingRecorderProvider] through a ListenableBuilder for
/// the same reason `_ServingSection` does: Riverpod 3 auto-pause trips an
/// assertion on providers that self-invalidate from a listener the framework
/// cannot see, and `Ref.invalidateSelfWhen` takes a Stream, which a
/// ChangeNotifier is not.
class _ProvenanceBadge extends ConsumerWidget {
  const _ProvenanceBadge({required this.item});

  final MediaItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(mediaProvenanceBadgesProvider)) {
      return const SizedBox.shrink();
    }
    final recorder = ref.watch(mediaServingRecorderProvider);

    return ListenableBuilder(
      listenable: recorder,
      builder: (context, _) {
        // thumbnail: true, because a GRID tile is what records here. The
        // viewer records the same row under thumbnail: false, and reading
        // that one would leave every grid badge on its fallback.
        final serving = ServingFacts.from(
          recorder.lastFor(item.id, thumbnail: true),
        );
        final source = displayedSourceFor(item, serving);

        return Tooltip(
          message: mediaSourceLabel(context.l10n, source),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => showMediaInfoSheet(context, item),
            child: Container(
              key: const Key('media-provenance-badge'),
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Icon(_iconFor(source), size: 12, color: Colors.white),
            ),
          ),
        );
      },
    );
  }

  /// Exhaustive with no default arm, so a new [ServedFrom] has to choose a
  /// glyph rather than inherit one.
  IconData _iconFor(ServedFrom source) => switch (source) {
    ServedFrom.localDisk => Icons.folder_outlined,
    ServedFrom.platformGallery => Icons.photo_library_outlined,
    // Cache versus network is the difference between "already here" and "came
    // down just now", which is exactly what a diver on a boat wants to know.
    ServedFrom.storeCache => Icons.cloud_done_outlined,
    ServedFrom.storeNetwork => Icons.cloud_outlined,
    ServedFrom.networkUrl => Icons.public,
    ServedFrom.connectorCache => Icons.cloud_done_outlined,
    ServedFrom.connectorNetwork => Icons.cloud_sync_outlined,
    ServedFrom.embedded => Icons.draw_outlined,
  };
}

/// Localized tooltip for a served source. Exhaustive with no default arm.
String mediaSourceLabel(AppLocalizations l10n, ServedFrom source) =>
    switch (source) {
      ServedFrom.localDisk => l10n.media_servedFrom_localDisk,
      ServedFrom.platformGallery => l10n.media_servedFrom_platformGallery,
      ServedFrom.storeCache => l10n.media_servedFrom_storeCache,
      ServedFrom.storeNetwork => l10n.media_servedFrom_storeNetwork,
      ServedFrom.networkUrl => l10n.media_servedFrom_networkUrl,
      ServedFrom.connectorCache => l10n.media_servedFrom_connectorCache,
      ServedFrom.connectorNetwork => l10n.media_servedFrom_connectorNetwork,
      ServedFrom.embedded => l10n.media_servedFrom_embedded,
    };

/// Localized tooltip for a status. Exhaustive with no default arm, so a new
/// state cannot ship without a string.
String mediaStatusLabel(AppLocalizations l10n, MediaStatus status) =>
    switch (status) {
      MediaStatus.broken => l10n.media_status_broken,
      MediaStatus.transferFailed => l10n.media_status_transferFailed,
      MediaStatus.transferring => l10n.media_status_transferring,
      MediaStatus.queued => l10n.media_status_queued,
      MediaStatus.cloudOnly => l10n.media_status_cloudOnly,
      MediaStatus.notBackedUp => l10n.media_status_notBackedUp,
      MediaStatus.none => '',
    };
