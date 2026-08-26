import 'package:flutter/material.dart';

import 'package:submersion/shared/utils/ink_centered_text_style.dart';

/// Badge for one of a dive's types (e.g. Wreck, Night, Drift).
///
/// Shares [DiveModeBadge]'s bordered-box shape, type scale, and font weight
/// so the two read as one family in the dive detail header, but sits a step
/// quieter: the border uses the lighter outlineVariant tone rather than the
/// mode badge's stronger outline, since a run of several type badges
/// shouldn't compete with the single OC/CCR indicator for attention. The
/// text splits the difference between outlineVariant (too low-contrast to
/// read as text) and onSurfaceVariant (the mode badge's full-strength
/// label color, too bright once several of these sit in a row) -- see
/// [_textColor]. Renders whatever [label] the caller passes in -- callers
/// typically resolve a short-form abbreviation via `diveTypeShortLabel`
/// first, falling back to the full localized name when none is available.
///
/// Translucent-filled (unlike [DiveModeBadge]'s bare outline): the header
/// can sit this badge over a live map background (see the location card in
/// dive_detail_page.dart), whose gradient scrim is only lightly tinted right
/// where the badge row sits. A fully transparent badge loses all contrast
/// there, but a fully opaque one reads as a heavy, out-of-place block next
/// to the plain-outline mode badge on a flat card -- so this splits the
/// difference with a low-alpha fill: enough of a backing to stay legible
/// over the map, faint enough to disappear into a flat card.
class DiveTypeBadge extends StatelessWidget {
  final String label;

  const DiveTypeBadge({super.key, required this.label});

  /// Matches [DiveModeBadge]'s non-dense font size: close to the header's
  /// titleMedium rating number, but a touch under it.
  static double fontSizeOf(BuildContext context) =>
      (Theme.of(context).textTheme.titleMedium?.fontSize ?? 16) - 3;

  /// Midpoint between outlineVariant and onSurfaceVariant: dim enough not to
  /// shout next to the mode badge, but still legible as text (outlineVariant
  /// alone reads fine as a 1px border, not as a run of glyphs). Derived from
  /// the theme tokens rather than a fixed color so it keeps adapting across
  /// light/dark and any accent-color theme.
  static Color _textColor(ColorScheme colorScheme) => Color.lerp(
    colorScheme.outlineVariant,
    colorScheme.onSurfaceVariant,
    0.5,
  )!;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      // Matches DiveModeBadge's padding, including the asymmetric vertical
      // split that compensates for the ink sitting a hair low within the
      // tight ascent/descent box textHeightBehavior forces.
      padding: const EdgeInsets.only(left: 4, right: 4, top: 2.5, bottom: 3.5),
      decoration: BoxDecoration(
        color: colorScheme.surface.withValues(alpha: 0.3),
        border: Border.all(color: colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall
            ?.copyWith(
              fontSize: fontSizeOf(context),
              color: _textColor(colorScheme),
              fontWeight: FontWeight.bold,
            )
            .inkCentered,
        textHeightBehavior: inkCenteredTextHeightBehavior,
      ),
    );
  }
}
