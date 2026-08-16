import 'package:flutter/material.dart';

import 'package:submersion/features/site_scape/presentation/site_terrain_pane.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// Thin fullscreen wrapper around [SiteTerrainPane], kept only until the
/// map hosts adopt the pane; deleted at the end of the unification work.
class SiteSeascapePage extends StatelessWidget {
  final String siteId;

  const SiteSeascapePage({super.key, required this.siteId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.dive3d_seascape_siteTitle)),
      body: SiteTerrainPane(siteId: siteId),
    );
  }
}
