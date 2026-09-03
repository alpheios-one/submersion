import 'package:flutter/material.dart';

import 'package:submersion/features/auto_update/domain/entities/linux_install_method.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// The action area of [UpdateBanner].
///
/// A packaged Linux install is upgraded by the system package manager, so this
/// shows the command rather than a download button: the app knows about the
/// release before the package manager has told the user, but it is not the
/// thing that should install it. Offering the tarball there would hand the user
/// an archive that shadows the packaged copy.
///
/// Split out of [UpdateBanner] so this behavior can be tested without
/// constructing UpdateStatusNotifier, whose constructor schedules a delayed
/// check that would leak a pending timer into every widget test.
class UpdateBannerActions extends StatelessWidget {
  const UpdateBannerActions({
    super.key,
    required this.installMethod,
    required this.downloadUrl,
    required this.onDownload,
    required this.onDismiss,
  });

  final LinuxInstallMethod installMethod;
  final String? downloadUrl;
  final ValueChanged<String> onDownload;
  final VoidCallback onDismiss;

  /// The command that upgrades a packaged install.
  static String upgradeCommand(LinuxInstallMethod method) => switch (method) {
    LinuxInstallMethod.deb => 'sudo apt upgrade submersion',
    LinuxInstallMethod.rpm => 'sudo dnf upgrade submersion',
    LinuxInstallMethod.tarball => '',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final url = downloadUrl;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (installMethod.isPackaged)
          Flexible(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: SelectableText(
                context.l10n.autoUpdate_banner_packageManagerHint(
                  upgradeCommand(installMethod),
                ),
                style: theme.textTheme.bodySmall,
              ),
            ),
          )
        else if (url != null)
          TextButton(
            onPressed: () => onDownload(url),
            child: Text(context.l10n.autoUpdate_banner_download),
          ),
        IconButton(
          icon: const Icon(Icons.close, size: 18),
          tooltip: context.l10n.common_action_dismiss,
          onPressed: onDismiss,
        ),
      ],
    );
  }
}
