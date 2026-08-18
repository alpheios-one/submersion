import 'package:flutter/material.dart';

import 'package:submersion/core/constants/enums.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/core/utils/currency.dart';
import 'package:submersion/core/utils/unit_formatter.dart';
import 'package:submersion/features/equipment/domain/entities/service_record.dart';
import 'package:submersion/features/equipment/domain/entities/service_kind.dart';
import 'package:submersion/features/equipment/presentation/providers/equipment_providers.dart';
import 'package:submersion/features/equipment/presentation/utils/service_type_label.dart';
import 'package:submersion/features/equipment/presentation/widgets/service_record_dialog.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// Service History Section Widget
class ServiceHistorySection extends ConsumerWidget {
  final String equipmentId;

  const ServiceHistorySection({super.key, required this.equipmentId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recordsAsync = ref.watch(serviceRecordNotifierProvider(equipmentId));
    final totalCostAsync = ref.watch(
      serviceRecordTotalCostProvider(equipmentId),
    );
    // Indexed once here rather than per row. While the kinds are still
    // loading the map is empty and rows fall back to the service type, which
    // is the right transient state: the history is already useful without the
    // task names, so blocking it behind a spinner would be worse.
    final kindsById = {
      for (final kind
          in ref.watch(serviceKindsProvider).valueOrNull ??
              const <ServiceKind>[])
        kind.id: kind,
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Expanded + ellipsis so a long translation of the title
                // ("Serviceverlauf") cannot overflow the header on a narrow
                // phone. The Add button keeps its natural width and wins the
                // space it needs.
                Expanded(
                  child: Row(
                    children: [
                      Icon(
                        Icons.history,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          context.l10n.equipment_service_historyTitle,
                          style: Theme.of(context).textTheme.titleMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed: () => _showAddServiceDialog(context, ref),
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(context.l10n.equipment_service_addButton),
                ),
              ],
            ),
            const Divider(),
            recordsAsync.when(
              data: (records) {
                if (records.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Column(
                        children: [
                          Icon(
                            Icons.build_outlined,
                            size: 48,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant
                                .withValues(alpha: 0.5),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            context.l10n.equipment_service_emptyState,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ],
                      ),
                    ),
                  );
                }

                return Column(
                  children: [
                    // Total cost summary, one row per currency: a history
                    // priced in more than one currency has no single total.
                    totalCostAsync.when(
                      data: (rawTotals) {
                        final totals = sumByCurrency<MapEntry<String, double>>(
                          rawTotals.entries,
                          amountOf: (e) => e.value,
                          currencyOf: (e) => e.key,
                          fallbackCode: ref.watch(defaultCurrencyProvider),
                        ).where((e) => e.value > 0).toList();
                        if (totals.isEmpty) return const SizedBox.shrink();
                        return Container(
                          padding: const EdgeInsets.all(12),
                          margin: const EdgeInsets.only(bottom: 12),
                          decoration: BoxDecoration(
                            color: Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Column(
                            children: [
                              for (final entry in totals)
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      context
                                          .l10n
                                          .equipment_service_totalCostLabel,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodyMedium,
                                    ),
                                    Text(
                                      formatMoney(entry.value, entry.key),
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.bold,
                                          ),
                                    ),
                                  ],
                                ),
                            ],
                          ),
                        );
                      },
                      loading: () => const SizedBox.shrink(),
                      error: (_, _) => const SizedBox.shrink(),
                    ),
                    // Service records list
                    ...records.map(
                      (record) => _ServiceRecordTile(
                        record: record,
                        kindsById: kindsById,
                        onTap: () =>
                            _showEditServiceDialog(context, ref, record),
                        onDelete: () =>
                            _confirmDeleteRecord(context, ref, record),
                      ),
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
                child: Text(
                  context.l10n.equipment_detail_errorMessage('$error'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showAddServiceDialog(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (context) => ServiceRecordDialog(
        equipmentId: equipmentId,
        onSave: (record) async {
          await ref
              .read(serviceRecordNotifierProvider(equipmentId).notifier)
              .addRecord(record);
        },
      ),
    );
  }

  void _showEditServiceDialog(
    BuildContext context,
    WidgetRef ref,
    ServiceRecord record,
  ) {
    showDialog(
      context: context,
      builder: (context) => ServiceRecordDialog(
        equipmentId: equipmentId,
        existingRecord: record,
        onSave: (updatedRecord) async {
          await ref
              .read(serviceRecordNotifierProvider(equipmentId).notifier)
              .updateRecord(updatedRecord);
        },
      ),
    );
  }

  Future<void> _confirmDeleteRecord(
    BuildContext context,
    WidgetRef ref,
    ServiceRecord record,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.equipment_service_deleteDialog_title),
        content: Text(
          context.l10n.equipment_service_deleteDialog_content(
            record.serviceType.label(context.l10n),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n.equipment_service_deleteDialog_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(context.l10n.equipment_service_deleteDialog_confirm),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ref
          .read(serviceRecordNotifierProvider(equipmentId).notifier)
          .deleteRecord(record.id);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.l10n.equipment_service_snackbar_deleted),
          ),
        );
      }
    }
  }
}

/// Service Record Tile Widget
class _ServiceRecordTile extends ConsumerWidget {
  final ServiceRecord record;

  /// Resolves [ServiceRecord.serviceKindId] to the maintenance task's name.
  /// Built once by the section rather than per row.
  final Map<String, ServiceKind> kindsById;

  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _ServiceRecordTile({
    required this.record,
    required this.kindsById,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final units = UnitFormatter(settings);
    final l10n = context.l10n;
    final theme = Theme.of(context);

    // The task answers "which of my jobs was done"; the type answers "what
    // category of work". Issue #829 asks for both, and the task is the one
    // that identifies the row, so it takes the title.
    final kindName = kindsById[record.serviceKindId]?.name;
    final typeLabel = record.serviceType.label(l10n);

    final providerAndCost = [
      if (record.provider != null && record.provider!.isNotEmpty)
        record.provider!,
      if (record.cost != null) formatMoney(record.cost!, record.currency),
    ].join(' · ');

    return ListTile(
      contentPadding: EdgeInsets.zero,
      isThreeLine: true,
      leading: CircleAvatar(
        backgroundColor: theme.colorScheme.primaryContainer,
        child: Icon(
          _getServiceTypeIcon(record.serviceType),
          color: theme.colorScheme.onPrimaryContainer,
          size: 20,
        ),
      ),
      // maxLines + ellipsis is a backstop: if a future change puts a
      // text-bearing widget back into trailing, the title ellipsizes instead
      // of rendering one glyph per line (issue #935).
      title: Text(
        kindName ?? typeLabel,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            kindName == null
                ? units.formatDate(record.serviceDate)
                : '$typeLabel · ${units.formatDate(record.serviceDate)}',
            style: theme.textTheme.bodySmall,
          ),
          if (providerAndCost.isNotEmpty)
            Text(providerAndCost, style: theme.textTheme.bodySmall),
          if (record.nextServiceDue != null)
            Text(
              l10n.equipment_service_nextDueLabel(
                units.formatDate(record.nextServiceDue!),
              ),
              style: theme.textTheme.bodySmall,
            ),
          if (record.notes.isNotEmpty)
            Text(
              record.notes,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
        ],
      ),
      // Only fixed-width widgets belong in trailing. _RenderListTile lays
      // trailing out against the full tile width and gives the title whatever
      // is left, clamped at zero, so a Text here starves the title (#935).
      // The cost lives in the subtitle column for that reason.
      trailing: PopupMenuButton<String>(
        onSelected: (value) {
          if (value == 'edit') {
            onTap();
          } else if (value == 'delete') {
            onDelete();
          }
        },
        itemBuilder: (context) => [
          PopupMenuItem(
            value: 'edit',
            child: Text(l10n.equipment_service_editMenuItem),
          ),
          PopupMenuItem(
            value: 'delete',
            child: Text(
              l10n.equipment_service_deleteMenuItem,
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
      onTap: onTap,
    );
  }

  IconData _getServiceTypeIcon(ServiceType type) {
    switch (type) {
      case ServiceType.annual:
        return Icons.event_repeat;
      case ServiceType.repair:
        return Icons.build;
      case ServiceType.inspection:
        return Icons.search;
      case ServiceType.overhaul:
        return Icons.settings_suggest;
      case ServiceType.replacement:
        return Icons.swap_horiz;
      case ServiceType.cleaning:
        return Icons.cleaning_services;
      case ServiceType.calibration:
        return Icons.tune;
      case ServiceType.warranty:
        return Icons.verified_user;
      case ServiceType.recall:
        return Icons.warning;
      case ServiceType.other:
        return Icons.handyman;
    }
  }
}
