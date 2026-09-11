import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import 'package:submersion/core/utils/unit_formatter.dart';
import 'package:submersion/features/dive_log/domain/entities/dive.dart';
import 'package:submersion/features/dive_log/presentation/providers/dive_providers.dart';
import 'package:submersion/features/nav_track/domain/entities/nav_track.dart';
import 'package:submersion/features/nav_track/domain/nav_track_corrector.dart';
import 'package:submersion/features/nav_track/domain/nav_track_stats.dart';
import 'package:submersion/features/nav_track/presentation/providers/nav_track_providers.dart';
import 'package:submersion/features/nav_track/presentation/widgets/nav_track_polyline_layer.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';

/// One route: stats, an inline map when anchored, its dive link, correction
/// status, and 3D (spec 2026-09-10-underwater-nav-track-design.md, "The
/// routes area", detail page).
class NavTrackDetailPage extends ConsumerWidget {
  const NavTrackDetailPage({super.key, required this.trackId});

  final String trackId;

  Future<void> _rename(
    BuildContext context,
    WidgetRef ref,
    NavTrack route,
  ) async {
    final controller = TextEditingController(text: route.name ?? '');
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename route'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (newName == null) return;
    await ref
        .read(navTrackRepositoryProvider)
        .rename(route.id, newName.trim().isEmpty ? null : newName.trim());
  }

  Future<void> _unlink(WidgetRef ref, NavTrack route) async {
    await ref.read(navTrackRepositoryProvider).unlink(route.id);
  }

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    NavTrack route,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete route?'),
        content: const Text('This cannot be undone.'),
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
    if (context.mounted) context.pop();
  }

  Future<void> _chooseDive(
    BuildContext context,
    WidgetRef ref,
    NavTrack route,
  ) async {
    final dives = await ref.read(divesProvider.future);
    final sorted = [...dives]
      ..sort(
        (a, b) =>
            (a.effectiveEntryTime.millisecondsSinceEpoch - route.startTime)
                .abs()
                .compareTo(
                  (b.effectiveEntryTime.millisecondsSinceEpoch -
                          route.startTime)
                      .abs(),
                ),
      );
    if (!context.mounted) return;
    final chosen = await showModalBottomSheet<Dive>(
      context: context,
      builder: (context) => ListView(
        shrinkWrap: true,
        children: [
          for (final dive in sorted.take(20))
            ListTile(
              title: Text('Dive #${dive.diveNumber ?? dive.id}'),
              subtitle: Text(
                UnitFormatter(
                  ref.read(settingsProvider),
                ).formatDateTime(dive.effectiveEntryTime),
              ),
              onTap: () => Navigator.of(context).pop(dive),
            ),
        ],
      ),
    );
    if (chosen == null) return;
    await ref
        .read(navTrackRepositoryProvider)
        .link(route.id, chosen.id, linkMode: NavTrackLinkMode.manual);
  }

  String _correctionStatus(NavTrack route) {
    return switch (route.endMode) {
      NavTrackEndMode.none => 'No correction applied yet.',
      NavTrackEndMode.sameAsStart => 'End set to same as start.',
      NavTrackEndMode.point => 'End point set on the map.',
      NavTrackEndMode.gpsFix => 'End set from the recording\'s GPS fix.',
    };
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final routeAsync = ref.watch(navTrackByIdProvider(trackId));
    final units = UnitFormatter(ref.watch(settingsProvider));

    return routeAsync.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => const Scaffold(
        body: Center(child: Text('Could not load this route.')),
      ),
      data: (route) {
        if (route == null) {
          return const Scaffold(body: Center(child: Text('Route not found.')));
        }
        final stats = NavTrackStats.of(route.points);
        return Scaffold(
          appBar: AppBar(
            title: Text(route.name ?? route.sourceRef ?? 'Route'),
            actions: [
              IconButton(
                key: const ValueKey('nav-track-open-3d'),
                icon: const Icon(Icons.view_in_ar),
                tooltip: 'Open 3D',
                onPressed: () => context.push('/nav-routes/${route.id}/3d'),
              ),
              PopupMenuButton<String>(
                onSelected: (value) async {
                  switch (value) {
                    case 'rename':
                      await _rename(context, ref, route);
                    case 'unlink':
                      await _unlink(ref, route);
                    case 'delete':
                      await _delete(context, ref, route);
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(value: 'rename', child: Text('Rename')),
                  if (route.diveId != null)
                    const PopupMenuItem(value: 'unlink', child: Text('Unlink')),
                  const PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _StatsCard(route: route, stats: stats, units: units),
              const SizedBox(height: 16),
              _LinkCard(
                route: route,
                onChooseDive: () => _chooseDive(context, ref, route),
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      const Icon(Icons.tune, size: 20),
                      const SizedBox(width: 8),
                      Expanded(child: Text(_correctionStatus(route))),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: 220,
                child: route.anchor == null
                    ? const Card(
                        child: Center(
                          child: Text(
                            'Set the start point to see this on a map.',
                          ),
                        ),
                      )
                    : ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: FlutterMap(
                          options: MapOptions(
                            initialCenter: LatLng(
                              route.anchor!.latitude,
                              route.anchor!.longitude,
                            ),
                            initialZoom: 15,
                          ),
                          children: [NavTrackPolylineLayer(route: route)],
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _StatsCard extends StatelessWidget {
  const _StatsCard({
    required this.route,
    required this.stats,
    required this.units,
  });

  final NavTrack route;
  final NavTrackStats stats;
  final UnitFormatter units;

  @override
  Widget build(BuildContext context) {
    final duration = Duration(seconds: stats.durationSeconds);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (route.deviceName != null) Text('Device: ${route.deviceName}'),
            Text('Distance: ${units.formatDistance(stats.totalDistance)}'),
            Text('Max depth: ${units.formatDepth(stats.maxDepth)}'),
            if (stats.maxSpeed != null)
              Text('Max speed: ${units.formatSpeed(stats.maxSpeed!)}'),
            if (stats.avgSpeed != null)
              Text('Avg speed: ${units.formatSpeed(stats.avgSpeed!)}'),
            Text(
              'Duration: ${duration.inHours}h ${duration.inMinutes.remainder(60)}min',
            ),
            if (route.points.isNotEmpty &&
                route.points.first.batteryVolts != null)
              Text(
                'Battery: ${route.points.first.batteryVolts!.toStringAsFixed(2)} V'
                ' -> ${_lastBattery(route)?.toStringAsFixed(2) ?? '?'} V',
              ),
          ],
        ),
      ),
    );
  }

  double? _lastBattery(NavTrack route) {
    for (final p in route.points.reversed) {
      if (p.batteryVolts != null) return p.batteryVolts;
    }
    return null;
  }
}

class _LinkCard extends ConsumerWidget {
  const _LinkCard({required this.route, required this.onChooseDive});

  final NavTrack route;
  final VoidCallback onChooseDive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final diveId = route.diveId;
    if (diveId == null) {
      return Card(
        child: ListTile(
          key: const ValueKey('nav-track-no-dive'),
          leading: const Icon(Icons.link_off),
          title: const Text('No dive linked'),
          trailing: TextButton(
            onPressed: onChooseDive,
            child: const Text('Choose dive'),
          ),
        ),
      );
    }
    final diveAsync = ref.watch(diveProvider(diveId));
    return Card(
      child: ListTile(
        key: const ValueKey('nav-track-linked-dive'),
        leading: const Icon(Icons.link),
        title: Text(
          diveAsync.value != null
              ? 'Dive #${diveAsync.value!.diveNumber ?? diveAsync.value!.id}'
              : 'Dive $diveId',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => context.push('/dives/$diveId'),
      ),
    );
  }
}
