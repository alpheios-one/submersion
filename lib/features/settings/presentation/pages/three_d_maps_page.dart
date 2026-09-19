import 'package:flutter/material.dart';

import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/bathymetry/application/bathymetry_reset_providers.dart';
import 'package:submersion/features/settings/presentation/widgets/bathymetry_refresh_tile.dart';
import 'package:submersion/features/settings/presentation/widgets/three_d_maps_reload_dialog.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// Settings page for the app's cached 3D terrain/depth data (bathymetry):
/// swissBATHY3D-specific actions, a combined reset for the other four
/// providers (EMODnet, NOAA DEM, GMRT, ETOPO), and a "reload for every dive
/// site" action that spans all five.
///
/// Only one of the four actions runs at a time: [_localBusy] covers the
/// three simple ones (the refresh tile reports its own run through
/// [BathymetryRefreshTile.onBusyChanged]), and [mapReloadProvider]'s own
/// `isRunning` covers the reload action, which has a dialog and a
/// cancellable progress bar of its own.
class ThreeDMapsPage extends ConsumerStatefulWidget {
  const ThreeDMapsPage({super.key});

  @override
  ConsumerState<ThreeDMapsPage> createState() => _ThreeDMapsPageState();
}

class _ThreeDMapsPageState extends ConsumerState<ThreeDMapsPage> {
  bool _localBusy = false;

  bool _busy(WidgetRef ref) =>
      _localBusy || ref.watch(mapReloadProvider).isRunning;

  Future<void> _runExclusive(
    Future<void> Function() action, {
    required String doneMessage,
  }) async {
    setState(() => _localBusy = true);
    try {
      await action();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(doneMessage)));
    } finally {
      if (mounted) setState(() => _localBusy = false);
    }
  }

  Future<void> _confirmAndRun({
    required String title,
    required String message,
    required String confirmLabel,
    required Future<void> Function() action,
    required String doneMessage,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n.common_action_cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _runExclusive(action, doneMessage: doneMessage);
  }

  Future<void> _startReload() async {
    final confirmed = await showMapReloadConfirmDialog(context, ref);
    if (confirmed != true || !mounted) return;
    await ref.read(mapReloadProvider.notifier).start();
    if (!mounted) return;
    final state = ref.read(mapReloadProvider);
    final message = state.error != null
        ? context.l10n.maps3d_reload_failed
        : state.cancelled
        ? context.l10n.maps3d_reload_cancelled
        : context.l10n.maps3d_reload_done;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final reloadState = ref.watch(mapReloadProvider);
    final busy = _busy(ref);

    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.maps3d_appBar_title)),
      body: ListView(
        children: [
          if (busy)
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.primaryContainer,
              padding: const EdgeInsets.all(12),
              child: Text(
                context.l10n.maps3d_busy_notice,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              ),
            ),
          _SectionHeader(context.l10n.maps3d_section_swissBathy),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                IgnorePointer(
                  ignoring: busy && !_localBusy,
                  child: BathymetryRefreshTile(
                    leading: const Icon(Icons.refresh),
                    onBusyChanged: (value) =>
                        setState(() => _localBusy = value),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  enabled: !busy,
                  leading: const Icon(Icons.delete_outline),
                  title: Text(context.l10n.maps3d_swissBathy_delete),
                  subtitle: Text(
                    context.l10n.maps3d_swissBathy_delete_subtitle,
                  ),
                  onTap: () => _confirmAndRun(
                    title: context.l10n.maps3d_swissBathy_delete_confirmTitle,
                    message:
                        context.l10n.maps3d_swissBathy_delete_confirmMessage,
                    confirmLabel: context.l10n.maps3d_swissBathy_delete,
                    action: ref.read(swissBathyClearProvider),
                    doneMessage: context.l10n.maps3d_swissBathy_delete_done,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SectionHeader(context.l10n.maps3d_section_other),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            child: ListTile(
              enabled: !busy,
              leading: const Icon(Icons.delete_sweep_outlined),
              title: Text(context.l10n.maps3d_other_reset),
              subtitle: Text(context.l10n.maps3d_other_reset_subtitle),
              onTap: () => _confirmAndRun(
                title: context.l10n.maps3d_other_reset_confirmTitle,
                message: context.l10n.maps3d_other_reset_confirmMessage,
                confirmLabel: context.l10n.maps3d_other_reset,
                action: ref.read(bathymetryOtherSourcesClearProvider),
                doneMessage: context.l10n.maps3d_other_reset_done,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                ListTile(
                  enabled: !busy,
                  leading: const Icon(Icons.cloud_download_outlined),
                  title: Text(context.l10n.maps3d_reload),
                  subtitle: Text(context.l10n.maps3d_reload_subtitle),
                  onTap: _startReload,
                ),
                if (reloadState.isRunning) ...[
                  const Divider(height: 1),
                  _ReloadProgress(state: reloadState),
                ],
              ],
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _ReloadProgress extends ConsumerWidget {
  const _ReloadProgress({required this.state});

  final MapReloadState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = state.total == 0 ? null : state.completed / state.total;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LinearProgressIndicator(value: progress),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                context.l10n.maps3d_reload_progress(
                  state.completed,
                  state.total,
                ),
              ),
              TextButton(
                onPressed: () => ref.read(mapReloadProvider.notifier).cancel(),
                child: Text(context.l10n.maps3d_reload_cancel),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
