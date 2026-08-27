import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/dive_sites/presentation/providers/site_match_review_notifier.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// After a multi-dive photo import, offers the batch site review for the
/// dives that just became eligible (siteless or coordinate-less site, now
/// with a GPS point, not dismissed). Silent when there is nothing to offer.
/// Pass [messenger] when the calling page is about to pop, so the snackbar
/// lands on the page underneath.
Future<void> offerSiteReviewAfterImport(
  BuildContext context,
  WidgetRef ref,
  Iterable<String> diveIds, {
  ScaffoldMessengerState? messenger,
}) async {
  // Sorted so the same dive set always produces the same
  // [ImportedDiveIds] key: it is an Equatable over the list, so two callers
  // holding the ids in different orders would otherwise address two separate
  // autoDispose family entries and repeat the query. The offer's own ordering
  // is unaffected, since the repository returns dives newest-first regardless.
  final ids = diveIds.toSet().toList()..sort();
  if (ids.isEmpty) return;
  final l10n = context.l10n;
  final scaffold = messenger ?? ScaffoldMessenger.of(context);
  // Best-effort: no router (embedded hosts, tests) or a failed eligibility
  // lookup means no offer, never a failed import.
  final router = GoRouter.maybeOf(context);
  if (router == null) return;
  final List<String> eligible;
  try {
    eligible = await ref.read(
      eligibleImportedDivesProvider(ImportedDiveIds(ids)).future,
    );
  } catch (_) {
    return;
  }
  if (eligible.isEmpty) return;
  scaffold.showSnackBar(
    SnackBar(
      content: Text(l10n.mediaImport_offerSiteReview(eligible.length)),
      duration: const Duration(seconds: 8),
      action: SnackBarAction(
        label: l10n.mediaImport_reviewSitesAction,
        onPressed: () => router.push('/dives/match-sites', extra: eligible),
      ),
    ),
  );
}
