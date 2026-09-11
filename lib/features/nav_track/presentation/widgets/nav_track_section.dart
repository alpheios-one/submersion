import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:submersion/core/services/logger_service.dart';
import 'package:submersion/core/utils/unit_formatter.dart';
import 'package:submersion/features/dive_log/domain/entities/dive.dart';
import 'package:submersion/features/dive_log/presentation/providers/dive_detail_ui_providers.dart';
import 'package:submersion/features/dive_log/presentation/widgets/collapsible_section.dart';
import 'package:submersion/features/nav_track/data/services/nav_track_import_service.dart';
import 'package:submersion/features/nav_track/data/services/parsers/parsed_nav_track.dart';
import 'package:submersion/features/nav_track/domain/entities/nav_track.dart';
import 'package:submersion/features/nav_track/domain/nav_track_stats.dart';
import 'package:submersion/features/nav_track/presentation/nav_track_parse_error_text.dart';
import 'package:submersion/features/nav_track/presentation/pages/nav_track_import_review_page.dart';
import 'package:submersion/features/nav_track/presentation/providers/nav_track_import_flow_providers.dart';
import 'package:submersion/features/nav_track/presentation/providers/nav_track_providers.dart';
import 'package:submersion/features/nav_track/presentation/widgets/nav_track_shape_thumbnail.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';

/// The dive detail "Underwater Route" section (spec
/// 2026-09-10-underwater-nav-track-design.md, "Dive detail section"):
/// linked routes, a way to link one, and a way to import a file straight to
/// this dive.
class NavTrackSection extends ConsumerWidget {
  const NavTrackSection({super.key, required this.dive});

  final Dive dive;

  Future<void> _linkRoute(BuildContext context, WidgetRef ref) async {
    final unlinked = await ref.read(unlinkedNavTracksProvider.future);
    final sorted = [...unlinked]
      ..sort(
        (a, b) => (a.startTime - dive.effectiveEntryTime.millisecondsSinceEpoch)
            .abs()
            .compareTo(
              (b.startTime - dive.effectiveEntryTime.millisecondsSinceEpoch)
                  .abs(),
            ),
      );
    if (!context.mounted) return;
    final chosen = await showModalBottomSheet<NavTrack>(
      context: context,
      builder: (context) => ListView(
        shrinkWrap: true,
        children: [
          for (final route in sorted)
            ListTile(
              title: Text(route.name ?? route.sourceRef ?? route.id),
              onTap: () => Navigator.of(context).pop(route),
            ),
        ],
      ),
    );
    if (chosen == null) return;
    await ref
        .read(navTrackRepositoryProvider)
        .link(chosen.id, dive.id, linkMode: NavTrackLinkMode.manual);
  }

  Future<void> _importFile(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final log = LoggerService.forClass(NavTrackSection);

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
      log.warning('Route import rejected: ${e.message}');
      messenger.showSnackBar(
        SnackBar(content: Text(navTrackParseErrorText(e))),
      );
      return;
    } catch (e, stackTrace) {
      log.error('Route import failed', error: e, stackTrace: stackTrace);
      messenger.showSnackBar(SnackBar(content: Text('Import failed: $e')));
      return;
    }

    await navigator.push<void>(
      MaterialPageRoute(
        builder: (_) => NavTrackImportReviewPage(
          bytes: bytes,
          fileName: file.name,
          preview: preview,
          preselectedDiveId: dive.id,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final routesAsync = ref.watch(navTracksForDiveProvider(dive.id));
    final unlinkedAsync = ref.watch(unlinkedNavTracksProvider);
    final routes = routesAsync.value ?? const <NavTrack>[];
    final isExpanded = ref.watch(navTrackSectionExpandedProvider);

    final subtitle = routes.isEmpty
        ? 'No route linked'
        : '${routes.length} route${routes.length == 1 ? '' : 's'}';

    return CollapsibleCardSection(
      title: 'Underwater Route',
      icon: Icons.route,
      collapsedSubtitle: subtitle,
      isExpanded: isExpanded,
      onToggle: (expanded) =>
          ref.read(navTrackSectionExpandedProvider.notifier).state = expanded,
      contentBuilder: (context) {
        if (!isExpanded) return const SizedBox.shrink();
        if (routes.isEmpty) {
          final hasUnlinked = (unlinkedAsync.value ?? const []).isNotEmpty;
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Divider(),
                const Text('No route linked'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    if (hasUnlinked)
                      OutlinedButton(
                        key: const ValueKey('nav-track-link-button'),
                        onPressed: () => _linkRoute(context, ref),
                        child: const Text('Link route'),
                      ),
                    OutlinedButton(
                      key: const ValueKey('nav-track-import-button'),
                      onPressed: () => _importFile(context, ref),
                      child: const Text('Import file'),
                    ),
                  ],
                ),
              ],
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Divider(),
              for (final route in routes) _RouteRow(route: route),
            ],
          ),
        );
      },
    );
  }
}

class _RouteRow extends ConsumerWidget {
  const _RouteRow({required this.route});

  final NavTrack route;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final units = UnitFormatter(ref.watch(settingsProvider));
    final stats = NavTrackStats.of(route.points);
    return Card(
      key: ValueKey('nav-track-row-${route.id}'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: NavTrackShapeThumbnail(points: route.points),
        title: Text(route.name ?? route.sourceRef ?? route.id),
        subtitle: Text(
          [
            if (route.deviceName != null) route.deviceName!,
            units.formatDistance(stats.totalDistance),
            units.formatDepth(stats.maxDepth),
            if (stats.maxSpeed != null) units.formatSpeed(stats.maxSpeed!),
            if (route.isPrimary) 'primary',
          ].join(' · '),
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (value) async {
            switch (value) {
              case 'unlink':
                await ref.read(navTrackRepositoryProvider).unlink(route.id);
              case 'primary':
                await ref.read(navTrackRepositoryProvider).setPrimary(route.id);
              case 'open':
                context.push('/nav-routes/${route.id}');
              case '3d':
                context.push('/nav-routes/${route.id}/3d');
            }
          },
          itemBuilder: (context) => [
            const PopupMenuItem(value: 'open', child: Text('Open route')),
            const PopupMenuItem(value: '3d', child: Text('Open 3D seascape')),
            const PopupMenuItem(value: 'unlink', child: Text('Unlink')),
            if (!route.isPrimary)
              const PopupMenuItem(
                value: 'primary',
                child: Text('Make primary'),
              ),
          ],
        ),
        onTap: () => context.push('/nav-routes/${route.id}'),
      ),
    );
  }
}
