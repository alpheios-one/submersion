import 'package:flutter/material.dart';

import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/media/domain/entities/media_item.dart';
import 'package:submersion/features/media/presentation/helpers/media_share_helper.dart';
import 'package:submersion/features/media/presentation/providers/media_providers.dart';
import 'package:submersion/features/media/presentation/providers/media_selection_provider.dart';
import 'package:submersion/features/media/presentation/widgets/dive_picker_sheet.dart';
import 'package:submersion/features/media_store/presentation/providers/media_store_providers.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// Action bar shown above the library while a selection is active: count,
/// Move to dive, Share, Unlink (with confirm), and a clear affordance.
class MediaSelectionBar extends ConsumerWidget {
  const MediaSelectionBar({super.key, required this.selectedItems});

  /// The currently selected items, resolved by the caller from the visible
  /// entries so share/unlink operate on real MediaItems.
  final List<MediaItem> selectedItems;

  List<String> get _ids => selectedItems.map((m) => m.id).toList();

  /// The library's one destructive action.
  ///
  /// A dive or a site can unlink from its own side and leave the row alive
  /// for the other one, but the library IS every side at once: unlinking
  /// here clears every link the row has, and a row with no link cannot stay
  /// in the library. So the row, its cloud proxies and its thumbnails go,
  /// and only the original source file is left alone. That single outcome is
  /// why this surface no longer carries an unlink-per-link pair alongside a
  /// separate Delete.
  ///
  /// Routed through the deletion coordinator so the remote-blob delete
  /// intent is enqueued before the rows die (orphan-prevention spec 5.2).
  Future<void> _unlinkSelected(BuildContext context, WidgetRef ref) async {
    final ids = _ids;
    if (ids.isEmpty) return;

    // Everything else an unlink discards is derived and rebuilds from the
    // source file on a re-link. A caption and the favorite flag live only in
    // Submersion's own row, so they are the part worth naming.
    final atRisk = await ref
        .read(mediaRepositoryProvider)
        .idsWithUserMetadata(ids);
    if (!context.mounted) return;

    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.media_library_unlinkConfirmTitle(ids.length)),
        content: Text(
          atRisk.isEmpty
              ? l10n.media_library_unlinkConfirmBody
              : '${l10n.media_library_unlinkConfirmBody}\n\n'
                    '${l10n.media_library_unlinkMetadataNote(atRisk.length)}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.common_action_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.media_library_unlinkSelected),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await ref.read(mediaDeletionCoordinatorProvider).deleteMultipleMedia(ids);
    ref.read(mediaSelectionProvider.notifier).clear();
  }

  Future<void> _moveToDive(BuildContext context, WidgetRef ref) async {
    final diveId = await showDivePickerSheet(context);
    if (diveId == null) return;
    await ref.read(mediaRepositoryProvider).reassignMediaToDive(_ids, diveId);
    ref.read(mediaSelectionProvider.notifier).clear();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: context.l10n.common_action_cancel,
              onPressed: () =>
                  ref.read(mediaSelectionProvider.notifier).clear(),
            ),
            Text(
              context.l10n.media_library_selectedCount(selectedItems.length),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(width: 8),
            // Three labelled actions plus the count still overflow a phone
            // in portrait, so the row scrolls rather than clipping.
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    TextButton.icon(
                      icon: const Icon(Icons.drive_file_move_outline),
                      label: Text(context.l10n.media_library_moveToDive),
                      onPressed: selectedItems.isEmpty
                          ? null
                          : () => _moveToDive(context, ref),
                    ),
                    TextButton.icon(
                      icon: const Icon(Icons.share),
                      label: Text(context.l10n.common_action_share),
                      onPressed: selectedItems.isEmpty
                          ? null
                          : () => shareMediaItems(context, ref, selectedItems),
                    ),
                    TextButton.icon(
                      key: const ValueKey('media_library_unlink'),
                      icon: const Icon(Icons.link_off),
                      label: Text(context.l10n.media_library_unlinkSelected),
                      onPressed: selectedItems.isEmpty
                          ? null
                          : () => _unlinkSelected(context, ref),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
