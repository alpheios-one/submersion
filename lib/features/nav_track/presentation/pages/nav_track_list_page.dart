import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:submersion/core/services/logger_service.dart';
import 'package:submersion/core/utils/unit_formatter.dart';
import 'package:submersion/features/dive_log/presentation/providers/dive_providers.dart';
import 'package:submersion/features/nav_track/data/services/nav_track_import_service.dart';
import 'package:submersion/features/nav_track/data/services/parsers/parsed_nav_track.dart';
import 'package:submersion/features/nav_track/domain/entities/nav_track.dart';
import 'package:submersion/features/nav_track/data/services/nav_track_service_providers.dart';
import 'package:submersion/features/nav_track/presentation/nav_track_parse_error_text.dart';
import 'package:submersion/features/nav_track/presentation/pages/nav_track_import_review_page.dart';
import 'package:submersion/features/nav_track/presentation/providers/nav_track_import_flow_providers.dart';
import 'package:submersion/features/nav_track/presentation/providers/nav_track_providers.dart';
import 'package:submersion/features/nav_track/presentation/widgets/nav_track_polyline_layer.dart';
import 'package:submersion/features/nav_track/presentation/widgets/nav_track_shape_thumbnail.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/shared/providers/map_list_selection_provider.dart';
import 'package:submersion/shared/widgets/map_list_layout/map_list_scaffold.dart';
import 'package:submersion/shared/widgets/master_detail/responsive_breakpoints.dart';

const String kNavTrackSectionKey = 'nav-track-list';

/// The routes area (spec 2026-09-10-underwater-nav-track-design.md, "The
/// routes area"): every measured underwater route, whether or not it is
/// linked to a dive, with unlinked routes first (`allNavTracksProvider`
/// already returns them in that order).
class NavTrackListPage extends ConsumerStatefulWidget {
  const NavTrackListPage({super.key});

  @override
  ConsumerState<NavTrackListPage> createState() => _NavTrackListPageState();
}

class _NavTrackListPageState extends ConsumerState<NavTrackListPage> {
  final _log = LoggerService.forClass(NavTrackListPage);
  final MapController _mapController = MapController();

  Future<void> _importFile() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['csv'],
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();

    final NavTrackImportPreview preview;
    try {
      preview = await ref
          .read(navTrackImportServiceProvider)
          .prepare(bytes, fileName: file.name);
    } on NavTrackParseException catch (e) {
      _log.warning('Route import rejected: ${e.message}');
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(navTrackParseErrorText(e))),
      );
      return;
    } catch (e, stackTrace) {
      _log.error('Route import failed', error: e, stackTrace: stackTrace);
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('Import failed: $e')));
      return;
    }

    if (!mounted) return;
    await navigator.push<void>(
      MaterialPageRoute(
        builder: (_) => NavTrackImportReviewPage(
          bytes: bytes,
          fileName: file.name,
          preview: preview,
        ),
      ),
    );
  }

  Future<void> _matchNow() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(navTrackMatchServiceProvider).sweep();
    } catch (e, stackTrace) {
      _log.error(
        'Manual route match sweep failed',
        error: e,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not match routes.')),
      );
      return;
    }
    if (!mounted) return;
    messenger.showSnackBar(
      const SnackBar(content: Text('Routes matched to dives.')),
    );
  }

  Future<void> _deleteRoute(NavTrack route) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete route?'),
        content: Text('Delete "${route.name ?? route.sourceRef ?? route.id}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(navTrackRepositoryProvider).delete(route.id);
    final selection = ref.read(mapListSelectionProvider(kNavTrackSectionKey));
    if (selection.selectedId == route.id) {
      ref
          .read(mapListSelectionProvider(kNavTrackSectionKey).notifier)
          .deselect();
    }
  }

  void _openRoute(String id) => context.push('/nav-routes/$id');

  Widget _importAction() => IconButton(
    key: const ValueKey('nav-track-import'),
    icon: const Icon(Icons.file_open_outlined),
    tooltip: 'Import route file',
    onPressed: _importFile,
  );

  Widget _matchAction() => IconButton(
    key: const ValueKey('nav-track-match'),
    icon: const Icon(Icons.sync),
    tooltip: 'Match now',
    onPressed: _matchNow,
  );

  @override
  Widget build(BuildContext context) {
    final routesAsync = ref.watch(allNavTracksProvider);
    final routes = routesAsync.value ?? const <NavTrack>[];
    final units = UnitFormatter(ref.watch(settingsProvider));

    if (!ResponsiveBreakpoints.isMasterDetail(context)) {
      return _buildColumn(context, routes, units);
    }

    final selection = ref.watch(mapListSelectionProvider(kNavTrackSectionKey));
    final anchoredRoutes = routes.where((r) => r.anchor != null).toList();

    return MapListScaffold(
      sectionKey: kNavTrackSectionKey,
      title: 'Underwater Routes',
      actions: [_matchAction(), _importAction()],
      listPane: _NavTrackListPane(
        routes: routes,
        selectedId: selection.selectedId,
        units: units,
        onSelect: (id) => ref
            .read(mapListSelectionProvider(kNavTrackSectionKey).notifier)
            .select(id),
        onOpen: _openRoute,
        onDelete: _deleteRoute,
      ),
      mapPane: anchoredRoutes.isEmpty
          ? const Center(child: Text('No routes are placed on the map yet.'))
          : FlutterMap(
              mapController: _mapController,
              options: const MapOptions(initialZoom: 12),
              children: [
                for (final route in anchoredRoutes)
                  NavTrackPolylineLayer(key: ValueKey(route.id), route: route),
              ],
            ),
    );
  }

  Widget _buildColumn(
    BuildContext context,
    List<NavTrack> routes,
    UnitFormatter units,
  ) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Underwater Routes'),
        actions: [_matchAction(), _importAction()],
      ),
      body: routes.isEmpty
          ? const Center(child: Text('No underwater routes yet.'))
          : ListView.builder(
              itemCount: routes.length,
              itemBuilder: (context, index) {
                final route = routes[index];
                return NavTrackListRow(
                  key: ValueKey(route.id),
                  route: route,
                  units: units,
                  onTap: () => _openRoute(route.id),
                  onDelete: () => _deleteRoute(route),
                );
              },
            ),
    );
  }
}

class _NavTrackListPane extends StatelessWidget {
  const _NavTrackListPane({
    required this.routes,
    required this.selectedId,
    required this.units,
    required this.onSelect,
    required this.onOpen,
    required this.onDelete,
  });

  final List<NavTrack> routes;
  final String? selectedId;
  final UnitFormatter units;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onOpen;
  final ValueChanged<NavTrack> onDelete;

  @override
  Widget build(BuildContext context) {
    if (routes.isEmpty) {
      return const Center(child: Text('No underwater routes yet.'));
    }
    return ListView.builder(
      itemCount: routes.length,
      itemBuilder: (context, index) {
        final route = routes[index];
        return NavTrackListRow(
          key: ValueKey(route.id),
          route: route,
          units: units,
          selected: route.id == selectedId,
          onTap: () {
            onSelect(route.id);
            onOpen(route.id);
          },
          onDelete: () => onDelete(route),
        );
      },
    );
  }
}

/// One route row: name, date, device, distance, max depth, duration, and a
/// link chip (`Dive #<n>` or "unlinked"). Unanchored routes show their shape
/// thumbnail in place of a map preview.
class NavTrackListRow extends ConsumerWidget {
  const NavTrackListRow({
    super.key,
    required this.route,
    required this.units,
    required this.onTap,
    required this.onDelete,
    this.selected = false,
  });

  final NavTrack route;
  final UnitFormatter units;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  /// `Dive #<n>` once the dive has loaded, its id while it is still
  /// resolving or missing, or "unlinked".
  String _linkLabel(WidgetRef ref) {
    final diveId = route.diveId;
    if (diveId == null) return 'unlinked';
    final dive = ref.watch(diveProvider(diveId)).value;
    if (dive == null) return 'Dive $diveId';
    return dive.diveNumber != null
        ? 'Dive #${dive.diveNumber}'
        : 'Dive $diveId';
  }

  String _formatDuration() {
    final seconds = ((route.endTime - route.startTime) / 1000).round();
    final d = Duration(seconds: seconds < 0 ? 0 : seconds);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    return h > 0 ? '${h}h ${m}min' : '${m}min';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final startedAt = DateTime.fromMillisecondsSinceEpoch(route.startTime);
    return ListTile(
      selected: selected,
      leading: route.anchor == null
          ? NavTrackShapeThumbnail(points: route.points)
          : const Icon(Icons.route),
      title: Text(route.name ?? route.sourceRef ?? route.id),
      subtitle: Text(
        [
          units.formatDate(startedAt),
          if (route.deviceName != null) route.deviceName!,
          if (route.totalDistance != null)
            units.formatDistance(route.totalDistance!),
          if (route.maxDepth != null) units.formatDepth(route.maxDepth),
          _formatDuration(),
        ].join(' · '),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          route.diveId == null
              ? Chip(
                  key: const ValueKey('nav-track-link-chip'),
                  label: Text(_linkLabel(ref)),
                )
              : ActionChip(
                  key: const ValueKey('nav-track-link-chip'),
                  label: Text(_linkLabel(ref)),
                  onPressed: () => context.push('/dives/${route.diveId}'),
                ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Delete',
            onPressed: onDelete,
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}
