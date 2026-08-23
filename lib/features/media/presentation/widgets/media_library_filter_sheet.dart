import 'package:flutter/material.dart';

import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/dive_sites/presentation/providers/site_providers.dart';
import 'package:submersion/features/media/domain/entities/media_item.dart';
import 'package:submersion/features/media/presentation/providers/media_library_providers.dart';
import 'package:submersion/features/media/presentation/providers/media_smart_album_providers.dart';
import 'package:submersion/features/media/presentation/widgets/media_library_filter_labels.dart';
import 'package:submersion/features/trips/presentation/providers/trip_providers.dart';
import 'package:submersion/l10n/l10n_extension.dart';
import 'package:submersion/shared/widgets/app_date_picker.dart';

/// Opens the library filter sheet. Returns when it closes; the sheet writes
/// [mediaLibraryFilterProvider] itself on Apply.
Future<void> showMediaLibraryFilterSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const MediaLibraryFilterSheet(),
  );
}

/// Draft-then-Apply filter editor for the media library, following the
/// SiteFilterSheet pattern: local state previews the change and nothing
/// reaches the provider until Apply.
///
/// Owns four facets: media type, site, trip, and date range. It deliberately
/// does NOT own sourceType or health, which other console sections set
/// programmatically, and which Apply preserves.
class MediaLibraryFilterSheet extends ConsumerStatefulWidget {
  const MediaLibraryFilterSheet({super.key});

  @override
  ConsumerState<MediaLibraryFilterSheet> createState() =>
      _MediaLibraryFilterSheetState();
}

class _MediaLibraryFilterSheetState
    extends ConsumerState<MediaLibraryFilterSheet> {
  MediaType? _mediaType;
  String? _siteId;
  String? _tripId;
  DateTime? _fromDate;
  DateTime? _toDate;

  @override
  void initState() {
    super.initState();
    final filter = ref.read(mediaLibraryFilterProvider);
    _mediaType = filter.mediaType;
    _siteId = filter.siteId;
    _tripId = filter.tripId;
    _fromDate = filter.fromDate;
    _toDate = filter.toDate;
  }

  void _clearAll() {
    setState(() {
      _mediaType = null;
      _siteId = null;
      _tripId = null;
      _fromDate = null;
      _toDate = null;
    });
  }

  /// Commits the draft ONTO THE LIVE FILTER, not onto a fresh one. The
  /// Sources section writes a sourceType into the same provider when the user
  /// browses a source; rebuilding from MediaLibraryFilter.none here would
  /// drop it and quietly widen the library.
  void _apply() {
    final notifier = ref.read(mediaLibraryFilterProvider.notifier);
    notifier.state = notifier.state.copyWith(
      mediaType: _mediaType,
      siteId: _siteId,
      tripId: _tripId,
      fromDate: _fromDate,
      toDate: _toDate,
    );
    Navigator.of(context).pop();
  }

  Future<void> _pickFromList({
    required List<(String id, String label)> options,
    required void Function(String? id) onPicked,
    required String anyLabel,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text(anyLabel),
              onTap: () {
                Navigator.of(sheetContext).pop();
                onPicked(null);
              },
            ),
            for (final (id, label) in options)
              ListTile(
                title: Text(label),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  onPicked(id);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickDates() async {
    final now = DateTime.now();
    final range = await showAppDateRangePicker(
      context: context,
      firstDate: DateTime(1970),
      lastDate: DateTime(now.year + 1),
    );
    if (range == null) return;
    setState(() {
      _fromDate = range.start;
      // Extend to end-of-day so a single-day range includes its media.
      _toDate = DateTime(
        range.end.year,
        range.end.month,
        range.end.day,
        23,
        59,
        59,
        999,
      );
    });
  }

  Future<void> _loadAlbum() async {
    final albums = ref.read(mediaSmartAlbumsProvider).value ?? const [];
    if (albums.isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final album in albums)
              ListTile(
                title: Text(album.name),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline, size: 18),
                  tooltip: context.l10n.media_smartAlbum_delete,
                  onPressed: () async {
                    Navigator.of(sheetContext).pop();
                    await _deleteAlbum(album.id);
                  },
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  setState(() {
                    _mediaType = album.filter.mediaType;
                    _siteId = album.filter.siteId;
                    _tripId = album.filter.tripId;
                    _fromDate = album.filter.fromDate;
                    _toDate = album.filter.toDate;
                  });
                },
              ),
          ],
        ),
      ),
    );
  }

  /// Awaited rather than fired and forgotten: an unawaited repository call
  /// turns a failed delete into an uncaught async error and leaves the album
  /// on screen with no explanation for why it came back.
  Future<void> _deleteAlbum(String id) async {
    try {
      await ref.read(mediaSmartAlbumRepositoryProvider).delete(id);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.media_smartAlbum_deleteFailed)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colorScheme = Theme.of(context).colorScheme;
    final sites = ref.watch(sitesProvider).value ?? const [];
    final trips = ref.watch(allTripsProvider).value ?? const [];
    final albums = ref.watch(mediaSmartAlbumsProvider).value ?? const [];

    final siteName = _siteId == null
        ? null
        : sites.where((s) => s.id == _siteId).firstOrNull?.name;
    final tripName = _tripId == null
        ? null
        : trips.where((t) => t.id == _tripId).firstOrNull?.name;
    // "Any", not "All": these read as "Site: Any", and reusing the type
    // chip's "All" both reads wrong and puts four identical labels in one
    // sheet.
    final anyLabel = l10n.media_library_filter_any;

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          // Transparent Material so the ListTiles inside paint their ink and
          // background above this decorated container (Flutter 3.44 asserts
          // on a ListTile whose nearest decorated ancestor precedes its
          // Material).
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              children: [
                Container(
                  margin: const EdgeInsets.symmetric(vertical: 12),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        l10n.media_library_filter_title,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      TextButton(
                        onPressed: _clearAll,
                        child: Text(l10n.diveSites_filter_clearAll),
                      ),
                    ],
                  ),
                ),
                const Divider(),
                Expanded(
                  child: ListView(
                    controller: scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    children: [
                      if (albums.isNotEmpty)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.bookmarks_outlined),
                          title: Text(l10n.media_smartAlbum_load),
                          onTap: _loadAlbum,
                        ),
                      const SizedBox(height: 8),
                      Text(
                        l10n.enum_sortField_type,
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: [
                          ChoiceChip(
                            label: Text(l10n.media_library_filter_all),
                            selected: _mediaType == null,
                            onSelected: (_) =>
                                setState(() => _mediaType = null),
                          ),
                          ChoiceChip(
                            label: Text(l10n.media_library_filter_photos),
                            selected: _mediaType == MediaType.photo,
                            onSelected: (_) =>
                                setState(() => _mediaType = MediaType.photo),
                          ),
                          ChoiceChip(
                            label: Text(l10n.media_library_filter_videos),
                            selected: _mediaType == MediaType.video,
                            onSelected: (_) =>
                                setState(() => _mediaType = MediaType.video),
                          ),
                        ],
                      ),
                      const Divider(height: 32),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(l10n.media_library_filter_site),
                        subtitle: Text(siteName ?? anyLabel),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _pickFromList(
                          options: [for (final s in sites) (s.id, s.name)],
                          onPicked: (id) => setState(() => _siteId = id),
                          anyLabel: anyLabel,
                        ),
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(l10n.media_library_filter_trip),
                        subtitle: Text(tripName ?? anyLabel),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _pickFromList(
                          options: [for (final t in trips) (t.id, t.name)],
                          onPicked: (id) => setState(() => _tripId = id),
                          anyLabel: anyLabel,
                        ),
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(l10n.media_library_filter_dates),
                        subtitle: Text(
                          _fromDate == null && _toDate == null
                              ? anyLabel
                              : formatFilterDateRange(
                                  context,
                                  _fromDate,
                                  _toDate,
                                ),
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _pickDates,
                      ),
                    ],
                  ),
                ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _apply,
                        child: Text(l10n.media_library_filter_apply),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
