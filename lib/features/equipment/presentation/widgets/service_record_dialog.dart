import 'package:flutter/material.dart';

import 'package:submersion/core/constants/enums.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/core/utils/currency.dart';
import 'package:submersion/core/utils/number_input.dart';
import 'package:submersion/core/utils/unit_formatter.dart';
import 'package:submersion/features/equipment/domain/entities/service_record.dart';
import 'package:submersion/features/equipment/presentation/providers/equipment_providers.dart';
import 'package:submersion/features/equipment/presentation/utils/service_type_label.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/l10n/l10n_extension.dart';
import 'package:submersion/shared/widgets/app_date_picker.dart';

/// Service Record Dialog for Add/Edit
class ServiceRecordDialog extends ConsumerStatefulWidget {
  final String equipmentId;
  final ServiceRecord? existingRecord;

  /// Pre-selects which service clock this record fulfills.
  final String? serviceKindId;
  final Future<void> Function(ServiceRecord) onSave;

  const ServiceRecordDialog({
    super.key,
    required this.equipmentId,
    this.existingRecord,
    this.serviceKindId,
    required this.onSave,
  });

  @override
  ConsumerState<ServiceRecordDialog> createState() =>
      _ServiceRecordDialogState();
}

class _ServiceRecordDialogState extends ConsumerState<ServiceRecordDialog> {
  final _formKey = GlobalKey<FormState>();
  late ServiceType _serviceType;
  late DateTime _serviceDate;
  final _providerController = TextEditingController();
  final _costController = TextEditingController();
  final _currencyController = TextEditingController();
  final _notesController = TextEditingController();
  DateTime? _nextServiceDue;
  String? _serviceKindId;
  bool _isSaving = false;

  /// The code this dialog opened with: the record's stored currency when
  /// editing, the diver's default for a new record. Currency is free text, so
  /// this can be outside the presets; keeping it lets the dropdown offer it.
  String _initialCurrencyCode = '';

  bool get isEditing => widget.existingRecord != null;

  @override
  void initState() {
    super.initState();
    if (isEditing) {
      final record = widget.existingRecord!;
      _serviceType = record.serviceType;
      _serviceDate = record.serviceDate;
      _providerController.text = record.provider ?? '';
      // Seeded in the diver's locale to match how the field is read back;
      // see formatDecimalForInput for why the two halves must agree.
      final cost = record.cost;
      _costController.text = cost == null ? '' : formatDecimalForInput(cost);
      _initialCurrencyCode = record.currency;
      _notesController.text = record.notes;
      _nextServiceDue = record.nextServiceDue;
      _serviceKindId = record.serviceKindId;
    } else {
      _serviceType = ServiceType.annual;
      _serviceDate = DateTime.now();
      _serviceKindId = widget.serviceKindId;
      _initialCurrencyCode = _fallbackCurrencyCode();
    }
    _currencyController.text = _initialCurrencyCode;
  }

  /// The code to store when the currency field is left blank: the diver's
  /// default, or USD if that is somehow unset (the column is NOT NULL).
  String _fallbackCurrencyCode() {
    final code = ref.read(defaultCurrencyProvider).trim().toUpperCase();
    return code.isEmpty ? 'USD' : code;
  }

  @override
  void dispose() {
    _providerController.dispose();
    _costController.dispose();
    _currencyController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final units = UnitFormatter(settings);

    return AlertDialog(
      title: Text(
        isEditing
            ? context.l10n.equipment_serviceDialog_editTitle
            : context.l10n.equipment_serviceDialog_addTitle,
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Service type dropdown
                DropdownButtonFormField<ServiceType>(
                  initialValue: _serviceType,
                  decoration: InputDecoration(
                    labelText:
                        context.l10n.equipment_serviceDialog_serviceTypeLabel,
                    prefixIcon: const Icon(Icons.build),
                  ),
                  items: ServiceType.values.map((type) {
                    return DropdownMenuItem(
                      value: type,
                      child: Text(type.label(context.l10n)),
                    );
                  }).toList(),
                  onChanged: (value) {
                    if (value != null) {
                      setState(() => _serviceType = value);
                    }
                  },
                ),
                const SizedBox(height: 16),

                // Service clock this record fulfills (resets that clock)
                ref
                    .watch(serviceKindsProvider)
                    .maybeWhen(
                      data: (kinds) => Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          DropdownButtonFormField<String?>(
                            initialValue:
                                kinds.any((k) => k.id == _serviceKindId)
                                ? _serviceKindId
                                : null,
                            decoration: InputDecoration(
                              labelText: context
                                  .l10n
                                  .equipment_serviceClocks_appliesToClock,
                              prefixIcon: const Icon(Icons.av_timer),
                            ),
                            items: [
                              DropdownMenuItem<String?>(
                                value: null,
                                child: Text(
                                  context
                                      .l10n
                                      .equipment_serviceClocks_noClockOption,
                                ),
                              ),
                              for (final kind in kinds)
                                DropdownMenuItem<String?>(
                                  value: kind.id,
                                  child: Text(kind.name),
                                ),
                            ],
                            onChanged: (value) {
                              setState(() => _serviceKindId = value);
                            },
                          ),
                          const SizedBox(height: 16),
                        ],
                      ),
                      orElse: () => const SizedBox.shrink(),
                    ),

                // Service date picker
                Semantics(
                  button: true,
                  label: context
                      .l10n
                      .equipment_serviceDialog_serviceDateSemanticLabel,
                  child: InkWell(
                    onTap: () => _pickServiceDate(),
                    child: InputDecorator(
                      decoration: InputDecoration(
                        labelText: context
                            .l10n
                            .equipment_serviceDialog_serviceDateLabel,
                        prefixIcon: const Icon(Icons.calendar_today),
                      ),
                      child: Text(units.formatDate(_serviceDate)),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Provider field
                TextFormField(
                  controller: _providerController,
                  decoration: InputDecoration(
                    labelText:
                        context.l10n.equipment_serviceDialog_providerLabel,
                    prefixIcon: const Icon(Icons.store),
                    hintText: context.l10n.equipment_serviceDialog_providerHint,
                  ),
                ),
                const SizedBox(height: 16),

                // Cost field, with the currency it is priced in.
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 2,
                      // Rebuild the cost field when the currency changes so
                      // its prefix shows the right symbol (EUR -> €, ...).
                      child: ValueListenableBuilder<TextEditingValue>(
                        valueListenable: _currencyController,
                        builder: (context, value, _) {
                          final symbol = currencySymbol(value.text);
                          return TextFormField(
                            controller: _costController,
                            decoration: InputDecoration(
                              labelText: context
                                  .l10n
                                  .equipment_serviceDialog_costLabel,
                              prefixText: symbol.isEmpty ? null : '$symbol ',
                              hintText:
                                  context.l10n.equipment_serviceDialog_costHint,
                            ),
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            validator: (value) {
                              if (value != null && value.isNotEmpty) {
                                final parsed = parseUserDecimal(value);
                                if (parsed == null || parsed < 0) {
                                  return context
                                      .l10n
                                      .equipment_serviceDialog_costValidation;
                                }
                              }
                              return null;
                            },
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      // Editable dropdown: common currencies as presets, but
                      // any ISO code can still be typed. The stored code leads
                      // the list when it is outside the presets.
                      child: DropdownMenu<String>(
                        controller: _currencyController,
                        expandedInsets: EdgeInsets.zero,
                        requestFocusOnTap: true,
                        enableFilter: true,
                        label: Text(
                          context.l10n.equipment_serviceDialog_currencyLabel,
                        ),
                        dropdownMenuEntries: [
                          for (final code in currencyCodesWith(
                            _initialCurrencyCode,
                          ))
                            DropdownMenuEntry(
                              value: code,
                              label: code,
                              leadingIcon: SizedBox(
                                width: 28,
                                child: Center(
                                  child: Text(currencySymbol(code)),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // Next service due date picker
                Semantics(
                  button: true,
                  label: context
                      .l10n
                      .equipment_serviceDialog_nextServiceDueSemanticLabel,
                  child: InkWell(
                    onTap: () => _pickNextServiceDate(),
                    child: InputDecorator(
                      decoration: InputDecoration(
                        labelText: context
                            .l10n
                            .equipment_serviceDialog_nextServiceDueLabel,
                        prefixIcon: const Icon(Icons.event),
                        suffixIcon: _nextServiceDue != null
                            ? IconButton(
                                icon: const Icon(Icons.clear),
                                tooltip: context
                                    .l10n
                                    .equipment_serviceDialog_clearNextServiceDateTooltip,
                                onPressed: () =>
                                    setState(() => _nextServiceDue = null),
                              )
                            : null,
                      ),
                      child: Text(
                        _nextServiceDue != null
                            ? units.formatDate(_nextServiceDue)
                            : context
                                  .l10n
                                  .equipment_serviceDialog_nextServiceNotSet,
                        style: TextStyle(
                          color: _nextServiceDue == null
                              ? Theme.of(context).colorScheme.onSurfaceVariant
                              : null,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Notes field
                TextFormField(
                  controller: _notesController,
                  decoration: InputDecoration(
                    labelText: context.l10n.equipment_serviceDialog_notesLabel,
                    prefixIcon: const Icon(Icons.notes),
                    alignLabelWithHint: true,
                  ),
                  maxLines: 3,
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
          child: Text(context.l10n.equipment_serviceDialog_cancelButton),
        ),
        FilledButton(
          onPressed: _isSaving ? null : _save,
          child: _isSaving
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(
                  isEditing
                      ? context.l10n.equipment_serviceDialog_updateButton
                      : context.l10n.equipment_serviceDialog_addButton,
                ),
        ),
      ],
    );
  }

  Future<void> _pickServiceDate() async {
    final picked = await showAppDatePicker(
      context: context,
      initialDate: _serviceDate,
      firstDate: DateTime(1950),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() => _serviceDate = picked);
    }
  }

  Future<void> _pickNextServiceDate() async {
    final picked = await showAppDatePicker(
      context: context,
      initialDate:
          _nextServiceDue ?? DateTime.now().add(const Duration(days: 365)),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365 * 10)),
    );
    if (picked != null) {
      setState(() => _nextServiceDue = picked);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isSaving = true);

    try {
      final now = DateTime.now();
      final record = ServiceRecord(
        id: widget.existingRecord?.id ?? '',
        equipmentId: widget.equipmentId,
        serviceType: _serviceType,
        serviceKindId: _serviceKindId,
        serviceDate: _serviceDate,
        provider: _providerController.text.trim().isEmpty
            ? null
            : _providerController.text.trim(),
        cost: parseUserDecimal(_costController.text),
        currency: _currencyController.text.trim().isEmpty
            ? _fallbackCurrencyCode()
            : _currencyController.text.trim().toUpperCase(),
        nextServiceDue: _nextServiceDue,
        notes: _notesController.text.trim(),
        createdAt: widget.existingRecord?.createdAt ?? now,
        updatedAt: now,
      );

      await widget.onSave(record);

      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isEditing
                  ? context.l10n.equipment_serviceDialog_snackbar_updated
                  : context.l10n.equipment_serviceDialog_snackbar_added,
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.l10n.equipment_serviceDialog_snackbar_error('$e'),
            ),
          ),
        );
        setState(() => _isSaving = false);
      }
    }
  }
}
