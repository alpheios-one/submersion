import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:submersion/core/constants/dive_detail_layout.dart';
import 'package:submersion/core/constants/dive_detail_sections.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// The dive detail page's display-options dropdown.
///
/// Puts the two page-shape choices where the page is -- which sections show,
/// and how much room each one gets -- instead of only under Settings. Both
/// write to the same per-diver settings the Settings page edits, so a choice
/// made here is the choice made there.
///
/// Section order is not editable from the menu: reordering wants drag handles
/// and a list that holds still, so the last item routes to the settings page
/// that already does it well.
class DiveDetailPropertiesMenu extends ConsumerWidget {
  const DiveDetailPropertiesMenu({super.key, required this.isGauge});

  /// Whether the dive is a gauge (bottom-timer) dive.
  ///
  /// Gauge dives never render the gas and decompression sections, so their
  /// toggles are left out rather than shown switched on with nothing behind
  /// them.
  final bool isGauge;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final sections = ref.watch(
      settingsProvider.select((s) => s.diveDetailSections),
    );
    final layout = ref.watch(
      settingsProvider.select((s) => s.diveDetailLayout),
    );
    final offered = [
      for (final section in sections)
        if (!(isGauge && section.id.hiddenInGaugeMode)) section,
    ];

    return MenuAnchor(
      alignmentOffset: const Offset(0, 8),
      style: const MenuStyle(
        maximumSize: WidgetStatePropertyAll(Size(340, 520)),
      ),
      menuChildren: [
        _MenuHeading(l10n.diveLog_detail_displayOptions_layout),
        for (final option in DiveDetailLayout.values)
          MenuItemButton(
            closeOnActivate: false,
            leadingIcon: Icon(
              option == layout
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
            ),
            onPressed: () =>
                ref.read(settingsProvider.notifier).setDiveDetailLayout(option),
            child: Text(option.localizedName(l10n)),
          ),
        const Divider(height: 8),
        _MenuHeading(l10n.diveLog_detail_displayOptions_sections),
        for (final section in offered)
          MenuItemButton(
            closeOnActivate: false,
            leadingIcon: Icon(
              section.visible ? Icons.check_box : Icons.check_box_outline_blank,
            ),
            trailingIcon: Icon(section.id.icon, size: 18),
            onPressed: () => _toggle(ref, sections, section),
            child: Text(section.id.localizedDisplayName(l10n)),
          ),
        const Divider(height: 8),
        MenuItemButton(
          closeOnActivate: false,
          leadingIcon: const Icon(Icons.checklist),
          onPressed: offered.every((s) => s.visible)
              ? null
              : () => _showAll(ref, sections),
          child: Text(l10n.diveLog_detail_displayOptions_showAll),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.reorder),
          onPressed: () => context.pushNamed('diveDetailSections'),
          child: Text(l10n.diveLog_detail_displayOptions_reorder),
        ),
      ],
      builder: (context, controller, _) => IconButton(
        icon: const Icon(Icons.tune),
        tooltip: l10n.diveLog_detail_displayOptions_tooltip,
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }

  void _toggle(
    WidgetRef ref,
    List<DiveDetailSectionConfig> sections,
    DiveDetailSectionConfig section,
  ) {
    final updated = [
      for (final s in sections)
        if (s.id == section.id) s.copyWith(visible: !s.visible) else s,
    ];
    ref.read(settingsProvider.notifier).setDiveDetailSections(updated);
  }

  /// Turns every section back on, leaving the diver's order alone.
  ///
  /// Deliberately not `resetDiveDetailSections`, which would also throw away
  /// a custom order the diver never asked to undo.
  void _showAll(WidgetRef ref, List<DiveDetailSectionConfig> sections) {
    final updated = [for (final s in sections) s.copyWith(visible: true)];
    ref.read(settingsProvider.notifier).setDiveDetailSections(updated);
  }
}

/// A non-interactive group label between runs of menu items.
class _MenuHeading extends StatelessWidget {
  const _MenuHeading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Text(
        text.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}
