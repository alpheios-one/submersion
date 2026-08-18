import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:submersion/features/media/domain/entities/media_item.dart';
import 'package:submersion/features/media/domain/entities/media_status.dart';
import 'package:submersion/features/media/presentation/providers/media_provenance_providers.dart';
import 'package:submersion/features/media/presentation/widgets/media_info_sheet.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// One glyph summarising an item's health, for grid tile overlays.
///
/// Quiet on success: a healthy, backed-up item renders nothing, so a badge on
/// screen always means "look at me" rather than decorating every thumbnail.
///
/// Supersedes the transfer-only badge this replaced. Deriving from
/// [mediaProvenanceProvider] rather than a second per-item queue watch also
/// halves the stream subscriptions a scrolling grid opens.
class MediaStatusBadge extends ConsumerWidget {
  const MediaStatusBadge({super.key, required this.item});

  final MediaItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = mediaStatusFor(ref.watch(mediaProvenanceProvider(item)));
    if (status == MediaStatus.none) return const SizedBox.shrink();

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
