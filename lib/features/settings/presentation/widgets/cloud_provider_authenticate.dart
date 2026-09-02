import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:submersion/core/data/repositories/sync_repository.dart'
    show CloudProviderType;
import 'package:submersion/core/services/cloud_storage/cloud_storage_provider.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// On desktop, Google Drive authentication round-trips through the
/// system browser (loopback OAuth); keep a cancellable waiting dialog up
/// while it completes so the caller's page does not look frozen. Other
/// providers and platforms authenticate directly.
///
/// Shared by Cloud Sync settings and the setup wizard's Backup & Sync step so
/// both connect surfaces behave identically: a wizard that authenticated
/// without the dialog would sit on a dead first-run screen for the whole
/// OAuth round trip, with no way to back out.
///
/// Throws [CloudStorageException] if the user cancels.
Future<void> authenticateWithBrowserWait(
  BuildContext context,
  CloudStorageProvider cloudProvider,
  CloudProviderType provider,
) async {
  final needsDialog =
      provider == CloudProviderType.googledrive &&
      (Platform.isWindows || Platform.isLinux);
  if (!needsDialog) {
    await cloudProvider.authenticate();
    return;
  }

  // Single synchronously-checked guard: whichever happens first -- auth
  // settling or the user tapping Cancel -- closes the dialog exactly once.
  // Because dialogClosed is checked and set with no intervening await, the
  // two paths can never interleave, so the pop always targets the dialog
  // (showDialog pushes it synchronously below, before any await yields to
  // the auth microtask) and never the page route.
  final navigator = Navigator.of(context, rootNavigator: true);
  var dialogClosed = false;
  void closeDialog(bool cancelled) {
    if (dialogClosed) return;
    dialogClosed = true;
    navigator.pop(cancelled);
  }

  final auth = cloudProvider.authenticate();
  unawaited(
    auth.then((_) => closeDialog(false), onError: (_) => closeDialog(false)),
  );
  final cancelled =
      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: Text(
            dialogContext.l10n.settings_cloudSync_googleDrive_browserWait_title,
          ),
          content: Text(
            dialogContext
                .l10n
                .settings_cloudSync_googleDrive_browserWait_message,
          ),
          actions: [
            TextButton(
              onPressed: () => closeDialog(true),
              child: Text(
                MaterialLocalizations.of(dialogContext).cancelButtonLabel,
              ),
            ),
          ],
        ),
      ) ??
      false;
  if (cancelled) {
    // Abandon the pending flow; the loopback listener times out on its
    // own. Swallow its eventual error so nothing surfaces later.
    unawaited(auth.catchError((_) {}));
    throw const CloudStorageException('Google Sign-In was cancelled');
  }
  await auth;
}
