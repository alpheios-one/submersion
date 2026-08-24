import 'package:flutter/material.dart';

import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/dive_sites/presentation/providers/site_providers.dart';

/// Lets the user pick one dive site by name. Resolves to the site id, or
/// null when dismissed.
Future<String?> showSitePickerSheet(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    builder: (sheetContext) => Consumer(
      builder: (context, ref, _) {
        final sites = ref.watch(sitesProvider).value ?? const [];
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final site in sites)
                ListTile(
                  title: Text(site.name),
                  onTap: () => Navigator.of(sheetContext).pop(site.id),
                ),
            ],
          ),
        );
      },
    ),
  );
}
