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
    final unassignedAsync = ref.watch(
      unassignedChannelIndexesForComputerProvider(diveComputerId),
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
                  onPressed: () => _showEntryDialog(
                    context,
                    ref,
                    null,
                    unassignedAsync.valueOrNull ?? const [],
                  ),
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(l10n.common_action_add),
                ),
              ],
            ),
            if ((unassignedAsync.valueOrNull ?? const []).isNotEmpty) ...[
              const SizedBox(height: 4),
              _UnassignedChannelsHint(channels: unassignedAsync.valueOrNull!),
            ],
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
                        onTap: () =>
                            _showEntryDialog(context, ref, entry, const []),
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
    List<int> unassignedChannels,
  ) {
    showDialog<void>(
      context: context,
      builder: (context) => _TransmitterDialog(
        diveComputerId: diveComputerId,
        existing: existing,
        unassignedChannels: unassignedChannels,
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

/// Non-blocking hint (issue #1365 import step 3) listing channel indices
/// seen in downloads from this computer that have no registry entry yet, so
/// the diver knows what to map without having to guess an index.
class _UnassignedChannelsHint extends StatelessWidget {
  final List<int> channels;

  const _UnassignedChannelsHint({required this.channels});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final channelList = channels
        .map((c) => l10n.diveComputer_transmitters_channelTitle(c))
        .join(', ');

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.info_outline,
          size: 16,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            l10n.diveComputer_transmitters_unassignedHint(channelList),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
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

  /// Channel indices seen in downloads from this computer that have no
  /// registry entry yet. When non-empty and adding a new entry, the channel
  /// field defaults to a picker over these instead of a free-text index
  /// (issue #1365 follow-up).
  final List<int> unassignedChannels;

  const _TransmitterDialog({
    required this.diveComputerId,
    this.existing,
    this.unassignedChannels = const [],
  });

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

  /// True once the diver picks from [_TransmitterDialog.unassignedChannels]
  /// or has to fall back to typing the index (editing, or nothing detected
  /// yet). False shows the detected-channel dropdown instead.
  late bool _manualChannelEntry;

  bool get _isEdit => widget.existing != null;
  bool get _hasDetectedChannels => widget.unassignedChannels.isNotEmpty;

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
    _manualChannelEntry = _isEdit || !_hasDetectedChannels;
    if (!_manualChannelEntry) {
      _channelController.text = '${widget.unassignedChannels.first}';
    }
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
              _buildChannelField(context, isEdit),
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

  /// The channel-index field: a dropdown over channels actually seen in
  /// downloads when there are any and a new entry is being added, otherwise
  /// the free-text fallback (issue #1365 follow-up). Either widget keeps
  /// [_channelController] in sync so [_save] never has to branch on mode.
  Widget _buildChannelField(BuildContext context, bool isEdit) {
    final l10n = context.l10n;

    if (isEdit || _manualChannelEntry) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextFormField(
            controller: _channelController,
            keyboardType: TextInputType.number,
            enabled: !isEdit,
            decoration: InputDecoration(
              labelText: l10n.diveComputer_transmitters_channelLabel,
              errorText: _errorText,
              helperText: !isEdit && !_hasDetectedChannels
                  ? l10n.diveComputer_transmitters_noChannelsDetected
                  : null,
              helperMaxLines: 3,
            ),
            validator: (value) {
              final parsed = int.tryParse(value ?? '');
              if (parsed == null || parsed < 0) {
                return l10n.tankPresets_edit_required;
              }
              return null;
            },
          ),
          if (!isEdit && _hasDetectedChannels)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => setState(() {
                  _manualChannelEntry = false;
                  _channelController.text =
                      '${widget.unassignedChannels.first}';
                }),
                child: Text(l10n.diveComputer_transmitters_useDetectedChannel),
              ),
            ),
        ],
      );
    }

    final selected = int.tryParse(_channelController.text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<int>(
          initialValue: widget.unassignedChannels.contains(selected)
              ? selected
              : widget.unassignedChannels.first,
          decoration: InputDecoration(
            labelText: l10n.diveComputer_transmitters_channelLabel,
            errorText: _errorText,
            helperText: l10n.diveComputer_transmitters_channelPickerHelper,
            helperMaxLines: 2,
          ),
          items: [
            for (final channel in widget.unassignedChannels)
              DropdownMenuItem<int>(
                value: channel,
                child: Text(
                  l10n.diveComputer_transmitters_channelTitle(channel),
                ),
              ),
          ],
          onChanged: (value) => setState(() {
            if (value != null) _channelController.text = '$value';
            _errorText = null;
          }),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => setState(() => _manualChannelEntry = true),
            child: Text(l10n.diveComputer_transmitters_channelManualOption),
          ),
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
