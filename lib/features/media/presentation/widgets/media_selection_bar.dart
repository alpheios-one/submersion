import 'package:flutter/material.dart';

import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/media/domain/entities/media_item.dart';
import 'package:submersion/features/media/presentation/helpers/media_share_helper.dart';
import 'package:submersion/features/media/presentation/providers/media_providers.dart';
import 'package:submersion/features/media/presentation/widgets/dive_picker_sheet.dart';
import 'package:submersion/features/media/presentation/widgets/unlink_metadata_warning_dialog.dart';
import 'package:submersion/features/media_store/presentation/providers/media_store_providers.dart';
import 'package:submersion/l10n/l10n_extension.dart';
import 'package:submersion/shared/selection/bulk_action.dart';
import 'package:submersion/shared/selection/selection_app_bar.dart';
import 'package:submersion/shared/selection/selection_controller.dart';

/// The library's contextual bar while a selection is active.
///
/// The chrome -- count, close, select all, deselect all, and delete tucked
/// into the overflow behind a divider -- comes from the shared
/// [SelectionAppBar], so the library cannot drift from every other selectable
/// surface. This widget contributes only the media-specific bulk actions and
/// the logic behind them.
class MediaSelectionBar extends ConsumerWidget {
  const MediaSelectionBar({
    super.key,
    required this.controller,
    required this.selectableIds,
    required this.selectedItems,
  });

  /// The library's selection state machine, shared with the view that hosts
  /// this bar.
  final SelectionController controller;

  /// Every id currently on screen, which is what Select All checks.
  final List<String> selectableIds;

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
    controller.exit();
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
    controller.exit();
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
    controller.exit();
  }

  Future<void> _moveToDive(BuildContext context, WidgetRef ref) async {
    final diveId = await showDivePickerSheet(context);
    if (diveId == null) return;
    await ref.read(mediaRepositoryProvider).reassignMediaToDive(_ids, diveId);
    controller.exit();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final anyDiveLinked = selectedItems.any((m) => m.diveId != null);
    final anySiteLinked = selectedItems.any((m) => m.siteId != null);

    // Share and Move come first so they hold the same two inline slots
    // whatever the selection contains; the conditional unlinks follow, which
    // keeps the row that can delete media out of the leftmost reach.
    return SelectionAppBar(
      controller: controller,
      selectableIds: selectableIds,
      shell: SelectionBarShell.pane,
      onDelete: () => _deleteSelected(context, ref),
      actions: [
        BulkAction(
          id: 'share',
          icon: Icons.share,
          label: l10n.common_action_share,
          onInvoke: () => shareMediaItems(context, ref, selectedItems),
        ),
        BulkAction(
          id: 'move_to_dive',
          icon: Icons.drive_file_move_outline,
          label: l10n.media_library_moveToDive,
          onInvoke: () => _moveToDive(context, ref),
        ),
        if (anyDiveLinked)
          BulkAction(
            id: 'unlink',
            icon: Icons.link_off,
            label: l10n.media_library_unlinkSelected,
            onInvoke: () => _unlinkFromDive(context, ref),
          ),
        if (anySiteLinked)
          BulkAction(
            id: 'unlink_site',
            icon: Icons.location_off,
            label: l10n.media_library_unlinkFromSite,
            onInvoke: () => _unlinkFromSite(context, ref),
          ),
      ],
    );
  }
}
