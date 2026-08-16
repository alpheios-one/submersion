import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/bathymetry/application/bathymetry_providers.dart';
import 'package:submersion/features/bathymetry/data/bathymetry_repository.dart';
import 'package:submersion/features/bathymetry/presentation/bathymetry_overlay_image.dart';
import 'package:submersion/features/dive_sites/domain/entities/dive_site.dart';
import 'package:submersion/features/site_scape/presentation/site_terrain_pane.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// How the site scape pane is showing its region: the host's 2D map, or
/// the 3D terrain of the selected site.
enum SiteScapeMode { map2d, terrain3d }

/// Mode-controlled morphable pane: the HOST owns the ephemeral
/// [SiteScapeMode] (each entry starts where the caller asked) and this
/// view renders the docked toggle, the host's 2D stack, and the terrain
/// pane. The 2D stack stays alive under [Offstage] so the map camera and
/// tiles survive mode flips. 3D needs a selected site and is disabled
/// when the site's grid is known to be absent; returning to 2D fits the
/// map camera to the grid bounds (camera continuity).
class SiteScapeView extends ConsumerStatefulWidget {
  final SiteScapeMode mode;
  final ValueChanged<SiteScapeMode> onModeChanged;
  final WidgetBuilder mapBuilder;
  final String? selectedSiteId;
  final GeoPoint? selectedSiteLocation;
  final MapController? mapController;

  const SiteScapeView({
    super.key,
    required this.mode,
    required this.onModeChanged,
    required this.mapBuilder,
    required this.selectedSiteId,
    required this.selectedSiteLocation,
    this.mapController,
  });

  @override
  ConsumerState<SiteScapeView> createState() => _SiteScapeViewState();
}

class _SiteScapeViewState extends ConsumerState<SiteScapeView> {
  @override
  void didUpdateWidget(covariant SiteScapeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Selection VANISHED while in 3D: fall back to the map. Transition
    // only (old non-null, new null): a deep link that starts in 3D before
    // the seeded selection lands must not be knocked back to 2D. Deferred
    // a frame because the host may be mid-build.
    if (widget.mode == SiteScapeMode.terrain3d &&
        oldWidget.selectedSiteId != null &&
        widget.selectedSiteId == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onModeChanged(SiteScapeMode.map2d);
      });
    }
    // 3D to 2D: fit the (still-alive, Offstage) map to the terrain box.
    if (oldWidget.mode == SiteScapeMode.terrain3d &&
        widget.mode == SiteScapeMode.map2d) {
      _fitMapToGrid();
    }
  }

  void _fitMapToGrid() {
    final controller = widget.mapController;
    final location = widget.selectedSiteLocation;
    if (controller == null || location == null) return;
    final grid = ref
        .read(bathymetryGridProvider(BathymetryRepository.quantize(location)))
        .valueOrNull;
    if (grid == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        controller.fitCamera(
          CameraFit.bounds(
            bounds: bathymetryGridBounds(grid),
            padding: const EdgeInsets.all(40),
          ),
        );
      } catch (_) {
        // Camera continuity is cosmetic: a not-yet-attached controller
        // (host swapped its map out) must never crash the mode switch.
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final location = widget.selectedSiteLocation;
    final gridAsync = location == null
        ? null
        : ref.watch(
            bathymetryGridProvider(BathymetryRepository.quantize(location)),
          );
    // Disabled only when the grid is KNOWN absent; while loading the
    // toggle stays live and the pane itself shows the no-data terminal
    // state if the fetch comes back empty.
    final gridKnownAbsent =
        gridAsync != null && gridAsync.hasValue && gridAsync.value == null;
    final canEnter3d = widget.selectedSiteId != null && !gridKnownAbsent;
    final show3d =
        widget.mode == SiteScapeMode.terrain3d && widget.selectedSiteId != null;

    return Stack(
      // Expand: the pane must fill its host slot even when the host's 2D
      // child is intrinsically sized, or the docked toggle would land
      // outside the Stack's bounds and become untappable.
      fit: StackFit.expand,
      children: [
        Offstage(offstage: show3d, child: widget.mapBuilder(context)),
        if (show3d)
          Positioned.fill(
            child: SiteTerrainPane(siteId: widget.selectedSiteId!),
          ),
        Positioned(
          top: 8,
          left: 8,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    key: const ValueKey('siteScape2dButton'),
                    icon: const Icon(Icons.map_outlined, size: 20),
                    isSelected: widget.mode == SiteScapeMode.map2d,
                    tooltip: context.l10n.siteScape_mode2d,
                    onPressed: () => widget.onModeChanged(SiteScapeMode.map2d),
                  ),
                  IconButton(
                    key: const ValueKey('siteScape3dButton'),
                    icon: const Icon(Icons.terrain, size: 20),
                    isSelected: widget.mode == SiteScapeMode.terrain3d,
                    tooltip: canEnter3d
                        ? context.l10n.siteScape_mode3d
                        : context.l10n.dive3d_seascape_noData,
                    onPressed: canEnter3d
                        ? () => widget.onModeChanged(SiteScapeMode.terrain3d)
                        : null,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
