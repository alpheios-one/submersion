import 'package:flutter/material.dart';

import 'package:submersion/l10n/l10n_extension.dart';

/// A tool listed on the Planning hub.
class PlanningTool {
  /// Stable identifier, also the last path segment of [route] and the value
  /// carried in the detail pane's `?tool=` query parameter.
  final String id;

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;

  /// Path this tool's [id] hangs off.
  ///
  /// Defaults to the hub. Gas Calculators owns a second level of tools, so
  /// its six calculators pass `/planning/gas-calculators` and route under it.
  final String routePrefix;

  /// Whether this tool always takes the whole window instead of opening in a
  /// detail pane.
  ///
  /// Set by the tools that run their own multi-pane layout, which cannot be
  /// nested inside what is left of the window beside a 440px master pane.
  /// See [kDivePlannerToolId].
  final bool fullPage;

  const PlanningTool({
    required this.id,
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    this.routePrefix = '/planning',
    this.fullPage = false,
  });

  String get route => '$routePrefix/$id';
}

/// Id of the dive planner.
///
/// The planner never opens in the detail pane: it has its own three-pane
/// layout (editor, chart, results) with thresholds at 760 and 1160px, and
/// squeezing that into what is left beside a 440px master pane would collapse
/// it to its narrowest form on all but enormous displays. It stays a
/// full-page push at every width.
///
/// Gas Calculators is the other tool in that position, for the same reason:
/// it renders its six calculators as a split view of its own. It says so with
/// [PlanningTool.fullPage] rather than by being rendered separately, because
/// unlike the planner it is an ordinary row in the tools list.
const String kDivePlannerToolId = 'dive-planner';

/// Id of the gas calculators hub, which owns a second level of tools.
const String kGasCalculatorsToolId = 'gas-calculators';

/// The calculators and readouts listed under the planner, in display order.
/// Each of these opens in the detail pane on desktop, unless it is marked
/// [PlanningTool.fullPage].
List<PlanningTool> planningToolsOf(BuildContext context) {
  final colorScheme = Theme.of(context).colorScheme;

  return [
    PlanningTool(
      id: 'deco-calculator',
      icon: Icons.calculate,
      color: colorScheme.secondary,
      title: context.l10n.planning_card_decoCalculator_title,
      subtitle: context.l10n.planning_card_decoCalculator_subtitle,
    ),
    PlanningTool(
      id: kGasCalculatorsToolId,
      icon: Icons.science,
      color: colorScheme.tertiary,
      title: context.l10n.planning_card_gasCalculators_title,
      subtitle: context.l10n.planning_card_gasCalculators_subtitle,
      fullPage: true,
    ),
    PlanningTool(
      id: 'weight-calculator',
      icon: Icons.fitness_center,
      color: colorScheme.primary.withValues(alpha: 0.8),
      title: context.l10n.planning_card_weightCalculator_title,
      subtitle: context.l10n.planning_card_weightCalculator_subtitle,
    ),
    PlanningTool(
      id: 'surface-interval',
      icon: Icons.timer,
      color: Colors.teal,
      title: context.l10n.planning_card_surfaceInterval_title,
      subtitle: context.l10n.planning_card_surfaceInterval_subtitle,
    ),
    PlanningTool(
      id: 'no-fly',
      icon: Icons.airplanemode_inactive,
      color: colorScheme.error,
      title: context.l10n.safetySettings_noFlyHeader,
      subtitle: context.l10n.planning_card_noFly_subtitle,
    ),
  ];
}
