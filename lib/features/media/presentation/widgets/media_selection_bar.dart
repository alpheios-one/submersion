import 'package:flutter/material.dart';

import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/media/domain/entities/media_item.dart';
import 'package:submersion/features/media/presentation/helpers/media_share_helper.dart';
import 'package:submersion/features/media/presentation/providers/media_providers.dart';
import 'package:submersion/features/media/presentation/providers/media_selection_provider.dart';
import 'package:submersion/features/media/presentation/widgets/dive_picker_sheet.dart';
import 'package:submersion/features/media/presentation/widgets/unlink_metadata_warning_dialog.dart';
import 'package:submersion/features/media_store/presentation/providers/media_store_providers.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// Action bar shown above the library while a selection is active: count,
/// Share, Delete (with confirm), and a clear affordance.
class MediaSelectionBar extends ConsumerWidget {
  const MediaSelectionBar({super.key, required this.selectedItems});

  /// The currently selected items, resolved by the caller from the visible
  /// entries so share/delete operate on real MediaItems.
  final List<MediaItem> selectedItems;

  Future<void> _deleteSelected(BuildContext context, WidgetRef ref) async {
    final l10n = context.l10n;
    final count = selectedItems.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.media_library_deleteConfirmTitle(count)),
        content: Text(l10n.media_library_deleteConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.common_action_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.common_action_delete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    // Routed through the deletion coordinator so the remote-blob delete
    // intent is enqueued before the rows die (orphan-prevention spec 5.2).
    await ref
        .read(mediaDeletionCoordinatorProvider)
        .deleteMultipleMedia(selectedItems.map((m) => m.id).toList());
    ref.read(mediaSelectionProvider.notifier).clear();
  }

  List<String> get _ids => selectedItems.map((m) => m.id).toList();

  /// Ids of the selection that actually carry a dive link: the service must
  /// only see rows the action applies to.
  List<String> get _diveLinkedIds =>
      selectedItems.where((m) => m.diveId != null).map((m) => m.id).toList();

  /// Same guard for the site link.
  List<String> get _siteLinkedIds =>
      selectedItems.where((m) => m.siteId != null).map((m) => m.id).toList();

  /// Unlinking removes the media from the library along with its cloud
  /// proxies and thumbnails; the original source file is untouched, and
  /// anything a dive site still needs keeps its row. Only a caption or a
  /// favorite is unrecoverable, so that is the one case worth a dialog.
  Future<void> _unlinkFromDive(BuildContext context, WidgetRef ref) async {
    final ids = _diveLinkedIds;
    if (ids.isEmpty) return;
    final service = ref.read(mediaUnlinkServiceProvider);

    final wouldLose = await service.idsWithUserMetadataAtRisk(ids);
    if (wouldLose.isNotEmpty) {
      if (!context.mounted) return;
      final go = await confirmUnlinkDiscardsMetadata(
        context,
        count: wouldLose.length,
      );
      if (!go) return;
    }

    await service.unlinkFromDive(ids);
    ref.read(mediaSelectionProvider.notifier).clear();
  }

  Future<void> _unlinkFromSite(BuildContext context, WidgetRef ref) async {
    final ids = _siteLinkedIds;
    if (ids.isEmpty) return;
    final service = ref.read(mediaUnlinkServiceProvider);

    final wouldLose = await service.idsWithUserMetadataAtRiskForSite(ids);
    if (wouldLose.isNotEmpty) {
      if (!context.mounted) return;
      final go = await confirmUnlinkDiscardsMetadata(
        context,
        count: wouldLose.length,
      );
      if (!go) return;
    }

    await service.unlinkFromSite(ids);
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
    final anyDiveLinked = selectedItems.any((m) => m.diveId != null);
    final anySiteLinked = selectedItems.any((m) => m.siteId != null);

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
            // The action set grows with selection context; scroll instead of
            // overflowing on narrow layouts.
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    if (anyDiveLinked)
                      TextButton.icon(
                        icon: const Icon(Icons.link_off),
                        label: Text(context.l10n.media_library_unlinkSelected),
                        onPressed: () => _unlinkFromDive(context, ref),
                      ),
                    if (anySiteLinked)
                      TextButton.icon(
                        icon: const Icon(Icons.location_off),
                        label: Text(context.l10n.media_library_unlinkFromSite),
                        onPressed: () => _unlinkFromSite(context, ref),
                      ),
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
                      icon: const Icon(Icons.delete_outline),
                      label: Text(context.l10n.common_action_delete),
                      onPressed: selectedItems.isEmpty
                          ? null
                          : () => _deleteSelected(context, ref),
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
