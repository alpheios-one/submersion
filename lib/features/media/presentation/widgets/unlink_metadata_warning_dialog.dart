import 'package:flutter/material.dart';

import 'package:submersion/l10n/l10n_extension.dart';

/// Confirms an unlink that would discard details the user entered.
///
/// Unlinking removes media from the library, and almost everything that goes
/// with it is derived: the cloud proxies and thumbnails rebuild from the
/// source file the moment it is linked again, and the original file is never
/// touched. A caption and the favorite flag are the exceptions. They live
/// only in Submersion's own row, so they are the only part of an unlink that
/// cannot be undone by re-linking.
///
/// Shown only when [count] is non-zero, so the ordinary case of tidying up
/// untagged media stays a single tap.
Future<bool> confirmUnlinkDiscardsMetadata(
  BuildContext context, {
  required int count,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(ctx.l10n.media_unlink_metadataLossTitle),
      content: Text(ctx.l10n.media_unlink_metadataLossContent(count)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(ctx.l10n.common_action_cancel),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(ctx.l10n.media_library_unlinkSelected),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
