import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/core/utils/unit_formatter.dart';
import 'package:submersion/features/dive_log/presentation/helpers/site_suggestion_actions.dart';
import 'package:submersion/features/dive_log/presentation/providers/dive_providers.dart';
import 'package:submersion/features/dive_log/presentation/widgets/site_suggestion_banner.dart';
import 'package:submersion/features/dive_sites/domain/entities/dive_site.dart';
import 'package:submersion/features/dive_sites/presentation/providers/site_providers.dart';
import 'package:submersion/features/dive_sites/presentation/providers/site_suggestion_providers.dart';
import 'package:submersion/features/media/presentation/widgets/quick_site_from_gps_dialog.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// Watches the site suggestion for [diveId] and renders the banner with its
/// actions wired. Renders nothing when there is no suggestion, so callers
/// place it unconditionally. Used by the dive edit and detail pages.
class SiteSuggestionCard extends ConsumerWidget {
  const SiteSuggestionCard({
    super.key,
    required this.diveId,
    required this.currentSite,
    this.onSiteChanged,
    this.refreshLists,
  });

  final String diveId;

  /// The site the host page currently shows for the dive (unsaved form
  /// state on the edit page); falls back to the dive's own site.
  final DiveSite? currentSite;

  /// Fires with the site the dive now has after assign / addLocation /
  /// create, so an edit form can update its unsaved state. Always the site
  /// the dive actually ended up linked to, re-read from the repository.
  final void Function(DiveSite site)? onSiteChanged;

  /// Refreshes the dive and site lists after a write. Injectable for tests.
  final Future<void> Function()? refreshLists;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final suggestion = ref.watch(siteSuggestionForDiveProvider(diveId)).value;
    if (suggestion == null) return const SizedBox.shrink();

    final proposal = suggestion.proposal;
    final units = UnitFormatter(ref.watch(settingsProvider));
    final hasSite = currentSite != null || proposal.dive.site != null;
    final recommended = proposal.recommendedCandidateId == null
        ? null
        : proposal.candidates
              .where((c) => c.id == proposal.recommendedCandidateId)
              .firstOrNull;
    final siteName =
        currentSite?.name ??
        proposal.dive.site?.name ??
        recommended?.name ??
        '';

    final actions = SiteSuggestionActions(
      diveId: diveId,
      suggestion: suggestion,
      diveRepository: ref.read(diveRepositoryProvider),
    );

    return SiteSuggestionBanner(
      pointSource: suggestion.pointSource,
      coordinates: units.formatCoordinates(
        suggestion.point.latitude,
        suggestion.point.longitude,
      ),
      status: proposal.status,
      hasSite: hasSite,
      siteName: siteName,
      candidateCount: proposal.candidates.length,
      recommendedDistanceMeters: recommended?.distanceMeters,
      onAssign: recommended == null
          ? null
          : () => _run(context, ref, (l10n) async {
              await actions.assign(recommended.id);
              // The candidate id is NOT necessarily the id the dive ends up
              // with: a bundled candidate materialises a new row, and the
              // coincidence guard can link an existing site nearby instead.
              // Re-read the dive so the form gets the real, fully hydrated
              // site rather than a partial entity built from the candidate.
              final linked = await ref
                  .read(diveRepositoryProvider)
                  .getDiveById(diveId);
              return (
                linked?.site,
                l10n.siteSuggestion_assignedSnack(
                  linked?.site?.name ?? recommended.name,
                ),
              );
            }),
      onChooseNearby: () => context.push('/dives/match-sites', extra: [diveId]),
      onCreate: () => _create(context, ref, actions, suggestion),
      onAddLocation: !hasSite
          ? null
          : () => _run(context, ref, (l10n) async {
              await actions.addLocation();
              final base = currentSite ?? proposal.dive.site!;
              final site = base.copyWith(location: suggestion.point);
              return (site, l10n.diveLog_edit_addedGps(site.name));
            }),
      onDismiss: () => _run(context, ref, (_) async {
        await actions.dismiss();
        return null;
      }),
    );
  }

  Future<void> _create(
    BuildContext context,
    WidgetRef ref,
    SiteSuggestionActions actions,
    SiteSuggestion suggestion,
  ) async {
    final draft = await QuickSiteFromGpsDialog.show(
      context,
      latitude: suggestion.point.latitude,
      longitude: suggestion.point.longitude,
    );
    if (draft == null || !context.mounted) return;
    await _run(context, ref, (l10n) async {
      final created = await actions.create(draft);
      return (created, l10n.diveLog_edit_createdSite(created.name));
    });
  }

  /// Runs a write, then refreshes what depends on it and reports the result:
  /// a message to show, and the site the dive now has (null when the write
  /// changed no site, or when re-reading it failed, in which case the form
  /// keeps what it had rather than adopting a guess).
  /// A failure keeps the banner up and shows the shared apply error.
  Future<void> _run(
    BuildContext context,
    WidgetRef ref,
    Future<(DiveSite?, String)?> Function(AppLocalizations l10n) write,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    try {
      final result = await write(l10n);
      ref.invalidate(siteSuggestionForDiveProvider(diveId));
      ref.invalidate(diveProvider(diveId));
      await (refreshLists ?? () => _defaultRefresh(ref))();
      if (result != null) {
        final site = result.$1;
        if (site != null) onSiteChanged?.call(site);
        messenger.showSnackBar(
          SnackBar(
            content: Text(result.$2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (_) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.siteMatchReview_applyError)),
      );
    }
  }

  Future<void> _defaultRefresh(WidgetRef ref) async {
    await ref.read(diveListNotifierProvider.notifier).refresh();
    await ref.read(paginatedDiveListProvider.notifier).refresh();
    await ref.read(siteListNotifierProvider.notifier).refresh();
  }
}
