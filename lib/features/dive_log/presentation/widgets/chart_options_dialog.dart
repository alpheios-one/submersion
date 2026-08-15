import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:submersion/core/constants/profile_metrics.dart';
import 'package:submersion/features/dive_log/domain/entities/dive.dart';
import 'package:submersion/l10n/l10n_extension.dart';
import 'package:submersion/features/dive_log/presentation/providers/profile_legend_provider.dart';
import 'package:submersion/features/dive_log/presentation/widgets/deco_stop_band.dart';
import 'package:submersion/features/dive_log/presentation/widgets/gas_colors.dart';
import 'package:submersion/features/dive_log/presentation/widgets/legend_candidates.dart';
import 'package:submersion/features/dive_log/presentation/widgets/o2_cell_readout.dart';
import 'package:submersion/features/dive_log/presentation/widgets/profile_legend_config.dart';

/// Persistent dialog for chart toggle options.
///
/// Uses [Consumer] to watch [profileLegendProvider] so checkbox states
/// update live without closing the dialog. Dismissed by tapping outside
/// (the transparent barrier).
class ChartOptionsDialog extends StatelessWidget {
  final ProfileLegendConfig config;
  final Offset anchorOffset;
  final Size anchorSize;

  const ChartOptionsDialog({
    super.key,
    required this.config,
    required this.anchorOffset,
    required this.anchorSize,
  });

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final bottomInset = MediaQuery.of(context).viewPadding.bottom;
    const edgePadding = 8.0;
    const dialogMaxWidth = 280.0;

    // Position below the button
    final top = anchorOffset.dy + anchorSize.height + 4;

    // Try to align the right edge of the dialog with the right edge of the
    // button, but clamp so the dialog never overflows the screen edges.
    final desiredRight = screenSize.width - anchorOffset.dx - anchorSize.width;
    final maxRight = screenSize.width - dialogMaxWidth - edgePadding;
    final right = desiredRight.clamp(edgePadding, maxRight);

    return Stack(
      children: [
        Positioned(
          top: top,
          right: right,
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(12),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: dialogMaxWidth,
                maxHeight: screenSize.height - top - edgePadding - bottomInset,
              ),
              child: Consumer(
                builder: (context, ref, _) {
                  final legendState = ref.watch(profileLegendProvider);
                  final legendNotifier = ref.read(
                    profileLegendProvider.notifier,
                  );

                  return SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: _buildSections(
                        context,
                        legendState: legendState,
                        legendNotifier: legendNotifier,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildSections(
    BuildContext context, {
    required ProfileLegendState legendState,
    required ProfileLegend legendNotifier,
  }) {
    final sections = <Widget>[];

    // Overlays section
    final overlayItems = <Widget>[
      if (config.hasTemperatureData)
        _buildToggleItem(
          context,
          label: context.l10n.diveLog_legend_label_temp,
          color: Theme.of(context).colorScheme.tertiary,
          isEnabled: legendState.showTemperature,
          onTap: legendNotifier.toggleTemperature,
        ),
      if (config.hasPressureData && !config.hasMultiTankPressure)
        _buildToggleItem(
          context,
          label: context.l10n.diveLog_legend_label_pressure,
          color: Colors.orange,
          isEnabled: legendState.showPressure,
          onTap: legendNotifier.togglePressure,
        ),
      if (config.hasEvents)
        _buildToggleItem(
          context,
          label: context.l10n.diveLog_legend_label_events,
          color: Colors.amber,
          isEnabled: legendState.showEvents,
          onTap: legendNotifier.toggleEvents,
        ),
      if (config.hasHeartRateData)
        _buildToggleItem(
          context,
          label: context.l10n.diveLog_legend_label_heartRate,
          color: Colors.red,
          isEnabled: legendState.showHeartRate,
          onTap: legendNotifier.toggleHeartRate,
        ),
      if (config.hasSacCurve)
        _buildToggleItem(
          context,
          label: context.l10n.diveLog_legend_label_sacRate,
          color: Colors.teal,
          isEnabled: legendState.showSac,
          onTap: legendNotifier.toggleSac,
        ),
      if (config.hasAscentRates)
        _buildToggleItem(
          context,
          label: context.l10n.diveLog_legend_label_ascentRate,
          color: Colors.lime.shade700,
          isEnabled: legendState.showAscentRateColors,
          onTap: legendNotifier.toggleAscentRateColors,
        ),
      if (config.hasAscentRates)
        _buildToggleItem(
          context,
          label: context.l10n.diveLog_legend_label_ascentRateLine,
          color: Colors.lime,
          isEnabled: legendState.showAscentRateLine,
          onTap: legendNotifier.toggleAscentRateLine,
        ),
      if (config.hasGasData)
        _buildGasToggleItem(
          context,
          label: context.l10n.diveLog_legend_label_showGas,
          isEnabled: legendState.showGas,
          onTap: legendNotifier.toggleGas,
        ),
    ];
    if (overlayItems.isNotEmpty) {
      sections.add(
        _buildSection(
          context,
          key: 'overlays',
          title: context.l10n.diveLog_chartSection_overlays,
          legendState: legendState,
          legendNotifier: legendNotifier,
          children: overlayItems,
        ),
      );
    }

    // Markers section
    final markerItems = <Widget>[
      if (config.hasMaxDepthMarker)
        _buildToggleItem(
          context,
          label: context.l10n.diveLog_legend_label_maxDepth,
          color: Colors.red,
          isEnabled: legendState.showMaxDepthMarker,
          onTap: legendNotifier.toggleMaxDepthMarker,
        ),
      if (config.hasPressureMarkers)
        _buildToggleItem(
          context,
          label: context.l10n.diveLog_legend_label_pressureThresholds,
          color: Colors.orange,
          isEnabled: legendState.showPressureMarkers,
          onTap: legendNotifier.togglePressureMarkers,
        ),
      if (config.hasGasSwitches)
        _buildToggleItem(
          context,
          label: context.l10n.diveLog_legend_label_gasSwitches,
          color: GasColors.nitrox,
          isEnabled: legendState.showGasSwitchMarkers,
          onTap: legendNotifier.toggleGasSwitchMarkers,
        ),
      if (config.hasPhotoMarkers)
        _buildToggleItem(
          context,
          label: context.l10n.diveLog_legend_label_photoMarkers,
          color: Colors.cyan,
          isEnabled: legendState.showPhotoMarkers,
          onTap: legendNotifier.togglePhotoMarkers,
        ),
    ];
    if (markerItems.isNotEmpty) {
      sections.add(
        _buildSection(
          context,
          key: 'markers',
          title: context.l10n.diveLog_chartSection_markers,
          legendState: legendState,
          legendNotifier: legendNotifier,
          children: markerItems,
        ),
      );
    }

    // Tanks section (for gas-switch dives without multi-tank pressure traces)
    if (config.hasTankListSection && config.tanks != null) {
      final sortedTanks = [...config.tanks!]
        ..sort((a, b) => a.order.compareTo(b.order));
      final tankItems = <Widget>[];

      for (var i = 0; i < sortedTanks.length; i++) {
        final tank = sortedTanks[i];
        final color = GasColors.forGasMix(tank.gasMix);
        final label = tankLegendLabel(context, tank, fallbackIndex: i + 1);

        tankItems.add(_buildStaticItem(context, label: label, color: color));
      }

      if (tankItems.isNotEmpty) {
        sections.add(
          _buildSection(
            context,
            key: 'tanks',
            title: context.l10n.diveLog_detail_section_cylinders,
            legendState: legendState,
            legendNotifier: legendNotifier,
            children: tankItems,
          ),
        );
      }
    }

    // Tank Pressures section
    if (config.hasMultiTankPressure && config.tankPressures != null) {
      final sortedTankIds = sortTankIdsByOrder(
        config.tankPressures!.keys,
        config.tanks,
      );
      final tankItems = <Widget>[];
      for (var i = 0; i < sortedTankIds.length; i++) {
        final tankId = sortedTankIds[i];
        final tank = _getTankById(tankId);
        final color = tank != null
            ? GasColors.forGasMix(tank.gasMix)
            : tankFallbackColor(i);
        final baseLabel = tank != null
            ? tankLegendLabel(context, tank, fallbackIndex: i + 1)
            : context.l10n.diveLog_tank_title(i + 1);
        final label = config.estimatedTankIds.contains(tankId)
            ? '$baseLabel ${context.l10n.diveLog_pressure_estimatedSuffix}'
            : baseLabel;

        tankItems.add(
          _buildToggleItem(
            context,
            label: label,
            color: color,
            isEnabled: legendState.showTankPressure[tankId] ?? true,
            onTap: () => legendNotifier.toggleTankPressure(tankId),
          ),
        );
      }
      if (tankItems.isNotEmpty) {
        sections.add(
          _buildSection(
            context,
            key: 'tankPressures',
            title: context.l10n.diveLog_chartSection_tankPressures,
            legendState: legendState,
            legendNotifier: legendNotifier,
            children: tankItems,
          ),
        );
      }
    }

    // Decompression section
    final decoItems = <Widget>[
      if (config.hasDecoStopCurve)
        _buildToggleWithSource(
          context,
          label: context.l10n.diveLog_legend_label_decoStops,
          color: decoStopBandColor,
          isEnabled: legendState.showDecoStops,
          onTap: legendNotifier.toggleDecoStops,
          currentSource: legendState.decoStopSource,
          onSourceChanged: legendNotifier.setDecoStopSource,
          segments: _sourceSegments(context),
          isAreaSwatch: true,
        ),
      if (config.hasCeilingCurve)
        // No source toggle: the ceiling line always shows the exact, continuous
        // calculated curve. Every import stores only the computer's stepped stop
        // depth, so a "computer" ceiling would duplicate the deco-stop band
        // (issue #755). The Computer/Calculated comparison lives on the deco
        // stops above.
        _buildToggleItem(
          context,
          label: context.l10n.diveLog_legend_label_ceiling,
          color: const Color(0xFFD32F2F),
          isEnabled: legendState.showCeiling,
          onTap: legendNotifier.toggleCeiling,
        ),
      if (config.hasNdlData)
        _buildToggleWithSource(
          context,
          label: context.l10n.diveLog_legend_label_ndl,
          color: Colors.yellow.shade700,
          isEnabled: legendState.showNdl,
          onTap: legendNotifier.toggleNdl,
          currentSource: legendState.ndlSource,
          onSourceChanged: legendNotifier.setNdlSource,
          segments: _sourceSegments(context),
        ),
      if (config.hasTtsData)
        _buildToggleWithSource(
          context,
          label: context.l10n.diveLog_legend_label_tts,
          color: const Color(0xFFAD1457),
          isEnabled: legendState.showTts,
          onTap: legendNotifier.toggleTts,
          currentSource: legendState.ttsSource,
          onSourceChanged: legendNotifier.setTtsSource,
          segments: _sourceSegments(context),
        ),
      if (config.hasCnsData)
        _buildToggleWithSource(
          context,
          label: context.l10n.diveLog_legend_label_cns,
          color: const Color(0xFFE65100),
          isEnabled: legendState.showCns,
          onTap: legendNotifier.toggleCns,
          currentSource: legendState.cnsSource,
          onSourceChanged: legendNotifier.setCnsSource,
          segments: _sourceSegments(context),
        ),
      if (config.hasOtuData)
        _buildToggleItem(
          context,
          label: context.l10n.diveLog_legend_label_otu,
          color: const Color(0xFF6D4C41),
          isEnabled: legendState.showOtu,
          onTap: legendNotifier.toggleOtu,
        ),
    ];
    if (decoItems.isNotEmpty) {
      sections.add(
        _buildSection(
          context,
          key: 'decompression',
          title: context.l10n.diveLog_chartSection_decompression,
          legendState: legendState,
          legendNotifier: legendNotifier,
          children: decoItems,
        ),
      );
    }

    // Gas Analysis section
    final gasItems = <Widget>[
      if (config.hasPpO2Data)
        _buildToggleItem(
          context,
          label: context.l10n.diveLog_legend_label_ppO2,
          color: const Color(0xFF00ACC1),
          isEnabled: legendState.showPpO2,
          onTap: legendNotifier.togglePpO2,
        ),
      if (config.hasPpN2Data)
        _buildToggleItem(
          context,
          label: context.l10n.diveLog_legend_label_ppN2,
          color: Colors.indigo,
          isEnabled: legendState.showPpN2,
          onTap: legendNotifier.togglePpN2,
        ),
      if (config.hasPpHeData)
        _buildToggleItem(
          context,
          label: context.l10n.diveLog_legend_label_ppHe,
          color: Colors.pink.shade300,
          isEnabled: legendState.showPpHe,
          onTap: legendNotifier.togglePpHe,
        ),
      if (config.hasO2CellMvData)
        _buildToggleWithSource(
          context,
          label: context.l10n.diveLog_legend_label_o2Cells,
          // Cell 1's colour, so the swatch belongs to the same set as the lines.
          color: o2CellColor(0),
          isEnabled: legendState.showO2CellMv,
          onTap: legendNotifier.toggleO2CellMv,
          currentSource: legendState.o2CellMode,
          onSourceChanged: legendNotifier.setO2CellMode,
          segments: [
            (
              O2CellDisplayMode.agreement,
              context.l10n.diveLog_legend_o2Cells_agreement,
            ),
            (
              O2CellDisplayMode.cells,
              context.l10n.diveLog_legend_o2Cells_cells,
            ),
          ],
        ),
      if (config.hasModData)
        _buildToggleItem(
          context,
          label: context.l10n.diveLog_legend_label_mod,
          color: Colors.deepOrange,
          isEnabled: legendState.showMod,
          onTap: legendNotifier.toggleMod,
        ),
      if (config.hasDensityData)
        _buildToggleItem(
          context,
          label: context.l10n.diveLog_legend_label_gasDensity,
          color: Colors.brown,
          isEnabled: legendState.showDensity,
          onTap: legendNotifier.toggleDensity,
        ),
    ];
    if (gasItems.isNotEmpty) {
      sections.add(
        _buildSection(
          context,
          key: 'gasAnalysis',
          title: context.l10n.diveLog_chartSection_gasAnalysis,
          legendState: legendState,
          legendNotifier: legendNotifier,
          children: gasItems,
        ),
      );
    }

    // Other section
    final otherItems = <Widget>[
      if (config.hasGfData)
        _buildToggleItem(
          context,
          label: context.l10n.diveLog_legend_label_gfPercent,
          color: Colors.deepPurple,
          isEnabled: legendState.showGf,
          onTap: legendNotifier.toggleGf,
        ),
      if (config.hasSurfaceGfData)
        _buildToggleItem(
          context,
          label: context.l10n.diveLog_legend_label_surfaceGf,
          color: Colors.purple.shade300,
          isEnabled: legendState.showSurfaceGf,
          onTap: legendNotifier.toggleSurfaceGf,
        ),
      if (config.hasMeanDepthData)
        _buildToggleItem(
          context,
          label: context.l10n.diveLog_legend_label_meanDepth,
          color: Colors.blueGrey,
          isEnabled: legendState.showMeanDepth,
          onTap: legendNotifier.toggleMeanDepth,
        ),
    ];
    if (otherItems.isNotEmpty) {
      sections.add(
        _buildSection(
          context,
          key: 'other',
          title: context.l10n.diveLog_chartSection_other,
          legendState: legendState,
          legendNotifier: legendNotifier,
          children: otherItems,
        ),
      );
    }

    // Display section: rendering behaviour rather than series visibility, so
    // it is always present and its items carry no series colour.
    sections.add(
      _buildSection(
        context,
        key: 'display',
        title: context.l10n.diveLog_chartSection_display,
        legendState: legendState,
        legendNotifier: legendNotifier,
        children: [
          _buildBehaviorItem(
            context,
            label: context.l10n.diveLog_chartOption_metricsFollowViewport,
            isEnabled: legendState.metricsFollowViewport,
            onTap: legendNotifier.toggleMetricsFollowViewport,
          ),
        ],
      ),
    );

    return sections;
  }

  Widget _buildSection(
    BuildContext context, {
    required String key,
    required String title,
    required ProfileLegendState legendState,
    required ProfileLegend legendNotifier,
    required List<Widget> children,
  }) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        key: PageStorageKey(key),
        title: Text(
          title,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.bold,
          ),
        ),
        initiallyExpanded: legendState.sectionExpanded[key] ?? false,
        onExpansionChanged: (expanded) =>
            legendNotifier.setSectionExpanded(key, expanded),
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        childrenPadding: EdgeInsets.zero,
        dense: true,
        children: children,
      ),
    );
  }

  /// Computer/Calculated segments, shared by every deco source switch.
  List<(MetricDataSource, String)> _sourceSegments(BuildContext context) => [
    (MetricDataSource.computer, context.l10n.diveLog_legend_source_dc),
    (MetricDataSource.calculated, context.l10n.diveLog_legend_source_calc),
  ];

  /// A toggle row with a segmented mode switch on the right. Generic over the
  /// mode enum so the deco source switches and the O2 cell display mode share
  /// one row implementation.
  Widget _buildToggleWithSource<T>(
    BuildContext context, {
    required String label,
    required Color color,
    required bool isEnabled,
    required VoidCallback onTap,
    required T currentSource,
    required ValueChanged<T> onSourceChanged,
    required List<(T, String)> segments,
    bool isAreaSwatch = false,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: [
            Icon(
              isEnabled ? Icons.check_box : Icons.check_box_outline_blank,
              size: 20,
              color: isEnabled
                  ? color
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            // Area metrics are drawn on the chart as a translucent shaded
            // region rather than a stroked curve, so their swatch is a filled
            // block in the same wash instead of a line.
            if (isAreaSwatch)
              Container(
                width: 16,
                height: 12,
                decoration: BoxDecoration(
                  color: color.withValues(
                    alpha: isEnabled
                        ? decoStopFillAlpha
                        : decoStopFillAlpha / 2,
                  ),
                  border: Border.all(
                    color: color.withValues(alpha: isEnabled ? 0.5 : 0.2),
                  ),
                  borderRadius: BorderRadius.circular(2),
                ),
              )
            else
              Container(
                width: 16,
                height: 4,
                decoration: BoxDecoration(
                  color: isEnabled ? color : color.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            const SizedBox(width: 8),
            Expanded(child: Text(label)),
            GestureDetector(
              onTap: () {}, // absorb tap to prevent parent InkWell from firing
              child: SizedBox(
                height: 28,
                child: SegmentedButton<T>(
                  segments: [
                    for (final (value, text) in segments)
                      ButtonSegment(
                        value: value,
                        label: Text(text, style: const TextStyle(fontSize: 11)),
                      ),
                  ],
                  selected: {currentSource},
                  onSelectionChanged: (selected) =>
                      onSourceChanged(selected.first),
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: WidgetStatePropertyAll(
                      EdgeInsets.symmetric(horizontal: 8),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Variant of [_buildToggleItem] for the gas-timeline visibility toggle.
  /// Replaces the single-color decoration stripe with four stacked bars in
  /// the air → nitrox → oxygen → trimix colors so the indicator visually
  /// advertises every gas type the strip can render, not just one.
  Widget _buildGasToggleItem(
    BuildContext context, {
    required String label,
    required bool isEnabled,
    required VoidCallback onTap,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final iconColor = isEnabled
        ? colorScheme.primary
        : colorScheme.onSurfaceVariant;
    Widget bar(Color color) => Container(
      width: 16,
      height: 3,
      decoration: BoxDecoration(
        color: isEnabled ? color : color.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(2),
      ),
    );

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(
              isEnabled ? Icons.check_box : Icons.check_box_outline_blank,
              size: 20,
              color: iconColor,
            ),
            const SizedBox(width: 8),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                bar(GasColors.air),
                const SizedBox(height: 1),
                bar(GasColors.nitrox),
                const SizedBox(height: 1),
                bar(GasColors.oxygen),
                const SizedBox(height: 1),
                bar(GasColors.trimix),
              ],
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(label)),
          ],
        ),
      ),
    );
  }

  /// Wraps a hand-rolled check-box row so assistive technology announces it as
  /// a checkbox with its state, not as an unlabelled button. The rows draw
  /// their own [Icons.check_box] rather than using [Checkbox], which carries no
  /// semantics of its own; [MergeSemantics] folds the state onto the same node
  /// as the [InkWell]'s tap action so the two are announced together.
  Widget _checkboxSemantics({required bool isEnabled, required Widget child}) =>
      MergeSemantics(
        child: Semantics(checked: isEnabled, child: child),
      );

  Widget _buildToggleItem(
    BuildContext context, {
    required String label,
    required Color color,
    required bool isEnabled,
    required VoidCallback onTap,
  }) {
    return _checkboxSemantics(
      isEnabled: isEnabled,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(
                isEnabled ? Icons.check_box : Icons.check_box_outline_blank,
                size: 20,
                color: isEnabled
                    ? color
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Container(
                width: 16,
                height: 4,
                decoration: BoxDecoration(
                  color: isEnabled ? color : color.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(label)),
            ],
          ),
        ),
      ),
    );
  }

  /// A checkbox row for a rendering-behaviour option. Unlike
  /// [_buildToggleItem] it carries no series colour swatch, because it does not
  /// correspond to a line on the chart.
  Widget _buildBehaviorItem(
    BuildContext context, {
    required String label,
    required bool isEnabled,
    required VoidCallback onTap,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return _checkboxSemantics(
      isEnabled: isEnabled,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(
                isEnabled ? Icons.check_box : Icons.check_box_outline_blank,
                size: 20,
                color: isEnabled
                    ? colorScheme.primary
                    : colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(label)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStaticItem(
    BuildContext context, {
    required String label,
    required Color color,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.circle, size: 12, color: color),
          const SizedBox(width: 12),
          Container(
            width: 16,
            height: 4,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(label)),
        ],
      ),
    );
  }

  /// Get tank by ID
  DiveTank? _getTankById(String tankId) {
    final tanks = config.tanks;
    if (tanks == null) return null;
    for (final tank in tanks) {
      if (tank.id == tankId) return tank;
    }
    return null;
  }
}
