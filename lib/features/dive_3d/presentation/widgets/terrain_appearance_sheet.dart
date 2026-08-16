import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:submersion/core/constants/units.dart';
import 'package:submersion/core/utils/number_input.dart';
import 'package:submersion/features/dive_3d/domain/spatial/seascape_appearance.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// Opens the terrain-appearance editor for the seascape views.
void showTerrainAppearanceSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const SafeArea(
      child: SingleChildScrollView(child: TerrainAppearanceSheet()),
    ),
  );
}

/// Issue #1065 knobs: ramp depth range, banded gradient, contour mode with
/// a custom level editor, line thickness, steep-wall angle. Every change
/// writes straight through SettingsNotifier (device-local persistence),
/// so both seascape pages and their providers react immediately.
class TerrainAppearanceSheet extends ConsumerWidget {
  const TerrainAppearanceSheet({super.key});

  static const List<int?> _palette = [
    null, // default ink
    0xFFEF4444,
    0xFFF97316,
    0xFFFDE047,
    0xFF10B981,
    0xFF3B82F6,
    0xFFA855F7,
  ];
  static const double _defaultRampMaxMeters = 40.0;

  /// Seed for a newly added custom level, in DISPLAY units: the editor rows
  /// read in the diver's unit, so a fixed metric seed would greet a feet
  /// diver with 32.8 rather than a round number.
  static const double _defaultNewLevelDisplay = 10.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final appearance = ref.watch(
      settingsProvider.select((s) => s.seascapeAppearance),
    );
    final depthUnit = ref.watch(settingsProvider.select((s) => s.depthUnit));
    final unitInMeters = depthUnit == DepthUnit.feet ? 0.3048 : 1.0;
    final notifier = ref.read(settingsProvider.notifier);
    void update(SeascapeAppearance next) =>
        notifier.setSeascapeAppearance(next);

    String depthText(double meters) {
      final v = meters / unitInMeters;
      final text = v % 1 == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
      return '$text ${depthUnit.symbol}';
    }

    final rampMax = appearance.rampMaxDepthMeters;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.dive3d_seascape_appearance,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          Text(l10n.dive3d_seascape_appearance_surface),
          const SizedBox(height: 8),
          SegmentedButton<SeascapeSurfaceMode>(
            key: const ValueKey('seascapeSurfaceModeSegments'),
            segments: [
              ButtonSegment(
                value: SeascapeSurfaceMode.depth,
                label: Text(l10n.dive3d_seascape_appearance_surfaceDepth),
              ),
              ButtonSegment(
                value: SeascapeSurfaceMode.imagery,
                label: Text(l10n.dive3d_seascape_appearance_surfaceImagery),
              ),
              ButtonSegment(
                value: SeascapeSurfaceMode.blend,
                label: Text(l10n.dive3d_seascape_appearance_surfaceBlend),
              ),
            ],
            selected: {appearance.surfaceMode},
            onSelectionChanged: (sel) =>
                update(appearance.copyWith(surfaceMode: sel.single)),
          ),
          SwitchListTile(
            key: const ValueKey('seascapeRampRangeSwitch'),
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.dive3d_seascape_appearance_rampRange),
            value: rampMax != null,
            onChanged: (on) => update(
              on
                  ? appearance.copyWith(
                      rampMaxDepthMeters: _defaultRampMaxMeters,
                    )
                  : appearance.copyWith(clearRampMax: true),
            ),
          ),
          if (rampMax != null)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.dive3d_seascape_appearance_rampMax),
              subtitle: Slider(
                key: const ValueKey('seascapeRampMaxSlider'),
                min: 5,
                max: 200,
                value: (rampMax / unitInMeters).clamp(5.0, 200.0),
                onChanged: (v) => update(
                  appearance.copyWith(
                    rampMaxDepthMeters: v.roundToDouble() * unitInMeters,
                  ),
                ),
              ),
              trailing: Text(depthText(rampMax)),
            ),
          SwitchListTile(
            key: const ValueKey('seascapeBandedSwitch'),
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.dive3d_seascape_appearance_banded),
            value: appearance.rampBanded,
            onChanged: (on) => update(appearance.copyWith(rampBanded: on)),
          ),
          const Divider(),
          Text(l10n.dive3d_seascape_appearance_contours),
          const SizedBox(height: 8),
          SegmentedButton<SeascapeContourMode>(
            key: const ValueKey('seascapeContourModeSegments'),
            segments: [
              ButtonSegment(
                value: SeascapeContourMode.auto,
                label: Text(l10n.dive3d_seascape_appearance_contourAuto),
              ),
              ButtonSegment(
                value: SeascapeContourMode.custom,
                label: Text(l10n.dive3d_seascape_appearance_contourCustom),
              ),
            ],
            selected: {appearance.contourMode},
            onSelectionChanged: (sel) =>
                update(appearance.copyWith(contourMode: sel.single)),
          ),
          if (appearance.contourMode == SeascapeContourMode.custom) ...[
            for (var i = 0; i < appearance.customLevels.length; i++)
              _levelRow(context, appearance, i, unitInMeters, update),
            TextButton.icon(
              key: const ValueKey('seascapeAddLevelButton'),
              icon: const Icon(Icons.add),
              label: Text(l10n.dive3d_seascape_appearance_addLevel),
              onPressed: () => update(
                appearance.copyWith(
                  customLevels: [
                    ...appearance.customLevels,
                    SeascapeContourLevel(
                      depthMeters: _defaultNewLevelDisplay * unitInMeters,
                    ),
                  ],
                ),
              ),
            ),
          ],
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.dive3d_seascape_appearance_wallAngle),
            subtitle: Slider(
              key: const ValueKey('seascapeWallAngleSlider'),
              min: 5,
              max: 90,
              divisions: 85,
              value: appearance.wallAngleDeg.clamp(5.0, 90.0),
              onChanged: (v) =>
                  update(appearance.copyWith(wallAngleDeg: v.roundToDouble())),
            ),
            trailing: Text('${appearance.wallAngleDeg.round()}°'),
          ),
          Text(
            l10n.dive3d_seascape_appearance_wallAngleNote,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _levelRow(
    BuildContext context,
    SeascapeAppearance appearance,
    int index,
    double unitInMeters,
    void Function(SeascapeAppearance) update,
  ) {
    final level = appearance.customLevels[index];
    List<SeascapeContourLevel> withLevel(SeascapeContourLevel? next) => [
      for (var i = 0; i < appearance.customLevels.length; i++)
        if (i != index) appearance.customLevels[i] else ?next,
    ];
    final display = level.depthMeters / unitInMeters;
    return Row(
      children: [
        SizedBox(
          width: 96,
          child: TextFormField(
            key: ValueKey('seascapeLevelField$index'),
            // Seeded and read in the same locale convention, or a diver whose
            // locale groups thousands with '.' would see "12.5" and have an
            // untouched resubmit store 125 (#1091).
            initialValue: formatDecimalForInput(
              display % 1 == 0 ? display : (display * 10).roundToDouble() / 10,
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onFieldSubmitted: (text) {
              final v = parseUserDecimal(text);
              if (v == null || v <= 0) return;
              update(
                appearance.copyWith(
                  customLevels: withLevel(
                    SeascapeContourLevel(
                      depthMeters: v * unitInMeters,
                      colorArgb: level.colorArgb,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(width: 12),
        DropdownButton<int?>(
          key: ValueKey('seascapeLevelColor$index'),
          value: level.colorArgb,
          items: [
            for (final c in _palette)
              DropdownMenuItem(
                value: c,
                child: c == null
                    ? Text(context.l10n.dive3d_seascape_appearance_defaultColor)
                    : CircleAvatar(radius: 8, backgroundColor: Color(c)),
              ),
          ],
          onChanged: (c) => update(
            appearance.copyWith(
              customLevels: withLevel(
                SeascapeContourLevel(
                  depthMeters: level.depthMeters,
                  colorArgb: c,
                ),
              ),
            ),
          ),
        ),
        const Spacer(),
        IconButton(
          key: ValueKey('seascapeLevelRemove$index'),
          icon: const Icon(Icons.delete_outline),
          onPressed: () =>
              update(appearance.copyWith(customLevels: withLevel(null))),
        ),
      ],
    );
  }
}
