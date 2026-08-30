import 'package:flutter/material.dart';

import 'package:submersion/core/constants/enums.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/dive_computer/domain/entities/transmitter_entity.dart';
import 'package:submersion/features/dive_computer/presentation/providers/transmitter_providers.dart';
import 'package:submersion/features/tank_presets/domain/entities/tank_preset_entity.dart';
import 'package:submersion/features/tank_presets/presentation/providers/tank_preset_providers.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// Section on the device detail page listing the transmitter (air-integration
/// channel) registry entries for a dive computer (issue #1365): the
/// deterministic channel-index-to-cylinder mapping applied on every
/// download, instead of relying on the orphan-to-tank heuristic and the
/// global default tank preset alone.
class TransmittersSection extends ConsumerWidget {
  final String diveComputerId;

  const TransmittersSection({super.key, required this.diveComputerId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entriesAsync = ref.watch(
      transmittersForComputerProvider(diveComputerId),
    );
    final theme = Theme.of(context);
    final l10n = context.l10n;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Icon(Icons.sensors, color: theme.colorScheme.primary),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          l10n.diveComputer_transmitters_title,
                          style: theme.textTheme.titleMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed: () => _showEntryDialog(context, ref, null),
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(l10n.common_action_add),
                ),
              ],
            ),
            const Divider(),
            entriesAsync.when(
              data: (entries) {
                if (entries.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text(
                        l10n.diveComputer_transmitters_emptyState,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  );
                }
                return Column(
                  children: [
                    for (final entry in entries)
                      _TransmitterTile(
                        entry: entry,
                        onTap: () => _showEntryDialog(context, ref, entry),
                        onDelete: () => _confirmDelete(context, ref, entry),
                      ),
                  ],
                );
              },
              loading: () => const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(),
                ),
              ),
              error: (error, _) => Center(
                child: Text(context.l10n.diveComputer_error_generic('$error')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showEntryDialog(
    BuildContext context,
    WidgetRef ref,
    TransmitterEntity? existing,
  ) {
    showDialog<void>(
      context: context,
      builder: (context) => _TransmitterDialog(
        diveComputerId: diveComputerId,
        existing: existing,
      ),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    TransmitterEntity entry,
  ) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.diveComputer_transmitters_deleteTitle),
        content: Text(
          l10n.diveComputer_transmitters_deleteMessage(entry.channelIndex),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.common_action_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(l10n.common_action_delete),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ref
          .read(transmitterListNotifierProvider(diveComputerId).notifier)
          .delete(entry.id);
    }
  }
}

class _TransmitterTile extends ConsumerWidget {
  final TransmitterEntity entry;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _TransmitterTile({
    required this.entry,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final role = TankRole.values
        .where((r) => r.name == entry.tankRole)
        .firstOrNull;
    final presetsAsync = ref.watch(tankPresetsProvider);
    final presetName = presetsAsync.valueOrNull
        ?.where((p) => p.id == entry.tankPresetId)
        .firstOrNull
        ?.displayName;

    final subtitleParts = [
      if (role != null) role.displayName,
      ?presetName,
    ].join(' · ');

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: theme.colorScheme.primaryContainer,
        child: Text('${entry.channelIndex}'),
      ),
      title: Text(
        entry.label?.isNotEmpty == true
            ? entry.label!
            : l10n.diveComputer_transmitters_channelTitle(entry.channelIndex),
      ),
      subtitle: subtitleParts.isEmpty ? null : Text(subtitleParts),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        onPressed: onDelete,
      ),
      onTap: onTap,
    );
  }
}

class _TransmitterDialog extends ConsumerStatefulWidget {
  final String diveComputerId;
  final TransmitterEntity? existing;

  const _TransmitterDialog({required this.diveComputerId, this.existing});

  @override
  ConsumerState<_TransmitterDialog> createState() => _TransmitterDialogState();
}

class _TransmitterDialogState extends ConsumerState<_TransmitterDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _channelController;
  late final TextEditingController _labelController;
  TankRole? _role;
  String? _tankPresetId;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _channelController = TextEditingController(
      text: existing == null ? '' : '${existing.channelIndex}',
    );
    _labelController = TextEditingController(text: existing?.label ?? '');
    _role = TankRole.values
        .where((r) => r.name == existing?.tankRole)
        .firstOrNull;
    _tankPresetId = existing?.tankPresetId;
  }

  @override
  void dispose() {
    _channelController.dispose();
    _labelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final presetsAsync = ref.watch(tankPresetsProvider);
    final isEdit = widget.existing != null;

    return AlertDialog(
      title: Text(
        isEdit
            ? l10n.diveComputer_transmitters_editTitle
            : l10n.diveComputer_transmitters_addTitle,
      ),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _channelController,
                keyboardType: TextInputType.number,
                enabled: !isEdit,
                decoration: InputDecoration(
                  labelText: l10n.diveComputer_transmitters_channelLabel,
                  errorText: _errorText,
                ),
                validator: (value) {
                  final parsed = int.tryParse(value ?? '');
                  if (parsed == null || parsed < 0) {
                    return l10n.tankPresets_edit_required;
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _labelController,
                decoration: InputDecoration(
                  labelText: l10n.diveComputer_transmitters_labelField,
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<TankRole?>(
                initialValue: _role,
                decoration: InputDecoration(
                  labelText: l10n.cylinderConfigs_role,
                ),
                items: [
                  DropdownMenuItem<TankRole?>(
                    value: null,
                    child: Text(l10n.diveComputer_transmitters_presetNone),
                  ),
                  for (final role in TankRole.values)
                    DropdownMenuItem<TankRole?>(
                      value: role,
                      child: Text(role.displayName),
                    ),
                ],
                onChanged: (value) => setState(() => _role = value),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                initialValue: _tankPresetId,
                decoration: InputDecoration(
                  labelText: l10n.diveComputer_transmitters_presetLabel,
                ),
                items: [
                  DropdownMenuItem<String?>(
                    value: null,
                    child: Text(l10n.diveComputer_transmitters_presetNone),
                  ),
                  for (final preset
                      in presetsAsync.valueOrNull ?? const <TankPresetEntity>[])
                    DropdownMenuItem<String?>(
                      value: preset.id,
                      child: Text(preset.displayName),
                    ),
                ],
                onChanged: (value) => setState(() => _tankPresetId = value),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.common_action_cancel),
        ),
        FilledButton(
          onPressed: () => _save(context),
          child: Text(l10n.common_action_save),
        ),
      ],
    );
  }

  Future<void> _save(BuildContext context) async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final channelIndex = int.parse(_channelController.text);
    final existing = widget.existing;
    final now = DateTime.now();

    final notifier = ref.read(
      transmitterListNotifierProvider(widget.diveComputerId).notifier,
    );

    if (existing == null) {
      final currentEntries = await ref.read(
        transmittersForComputerProvider(widget.diveComputerId).future,
      );
      if (currentEntries.any((e) => e.channelIndex == channelIndex)) {
        setState(() {
          _errorText =
              context.l10n.diveComputer_transmitters_duplicateChannelError;
        });
        return;
      }
    }

    final entry = TransmitterEntity(
      id: existing?.id ?? '',
      diveComputerId: widget.diveComputerId,
      channelIndex: channelIndex,
      label: _labelController.text.trim().isEmpty
          ? null
          : _labelController.text.trim(),
      tankRole: _role?.name,
      tankPresetId: _tankPresetId,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
    );

    await notifier.upsert(entry);
    if (context.mounted) Navigator.of(context).pop();
  }
}
