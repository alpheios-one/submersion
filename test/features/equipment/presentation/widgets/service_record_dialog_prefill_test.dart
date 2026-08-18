import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:submersion/core/constants/enums.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/equipment/domain/entities/service_kind.dart';
import 'package:submersion/features/equipment/domain/entities/service_record.dart';
import 'package:submersion/features/equipment/domain/entities/service_schedule.dart';
import 'package:submersion/features/equipment/presentation/providers/equipment_providers.dart';
import 'package:submersion/features/equipment/presentation/widgets/service_record_dialog.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

import '../../../../helpers/mock_providers.dart';

const costFieldKey = Key('service-record-cost');

void main() {
  final t0 = DateTime(2026, 1, 1);

  ServiceKind kind({double? cost, String? currency}) => ServiceKind(
    id: 'scrubber-repack',
    name: 'Scrubber repack',
    defaultCost: cost,
    defaultCurrency: currency,
    createdAt: t0,
    updatedAt: t0,
  );

  ServiceSchedule schedule({double? cost, String? currency}) => ServiceSchedule(
    id: 's1',
    equipmentId: 'e1',
    serviceKindId: 'scrubber-repack',
    defaultCost: cost,
    defaultCurrency: currency,
    createdAt: t0,
    updatedAt: t0,
  );

  Future<void> pumpDialog(
    WidgetTester tester, {
    double? kindCost,
    double? scheduleCost,
    String? serviceKindId = 'scrubber-repack',
    ServiceRecord? existingRecord,
    Future<void> Function(ServiceRecord)? onSave,
  }) async {
    final overrides = await getBaseOverrides();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...overrides,
          serviceKindsProvider.overrideWith(
            (ref) async => [kind(cost: kindCost, currency: 'EUR')],
          ),
          serviceSchedulesForEquipmentProvider(
            'e1',
          ).overrideWith((ref) async => [schedule(cost: scheduleCost)]),
        ].cast(),
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ServiceRecordDialog(
              equipmentId: 'e1',
              serviceKindId: serviceKindId,
              existingRecord: existingRecord,
              onSave: onSave ?? (record) async {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  String costText(WidgetTester tester) =>
      tester.widget<TextFormField>(find.byKey(costFieldKey)).controller!.text;

  testWidgets('creating a record prefills the schedule price', (tester) async {
    await pumpDialog(tester, kindCost: 60, scheduleCost: 45);
    expect(costText(tester), '45');
  });

  testWidgets('the kind price is used when the schedule has none', (
    tester,
  ) async {
    await pumpDialog(tester, kindCost: 60);
    expect(costText(tester), '60');
  });

  testWidgets('editing an existing record never prefills', (tester) async {
    // A cost the diver deliberately cleared must stay cleared.
    final existing = ServiceRecord(
      id: 'r1',
      equipmentId: 'e1',
      serviceType: ServiceType.cleaning,
      serviceKindId: 'scrubber-repack',
      serviceDate: t0,
      createdAt: t0,
      updatedAt: t0,
    );
    await pumpDialog(
      tester,
      kindCost: 60,
      scheduleCost: 45,
      existingRecord: existing,
    );
    expect(costText(tester), isEmpty);
  });

  testWidgets('an untagged new record prefills nothing', (tester) async {
    await pumpDialog(tester, kindCost: 60, serviceKindId: null);
    expect(costText(tester), isEmpty);
  });

  testWidgets('a cost the diver has typed is not overwritten', (tester) async {
    await pumpDialog(tester, kindCost: 60);
    expect(costText(tester), '60');

    await tester.enterText(find.byKey(costFieldKey), '99');
    await tester.pumpAndSettle();

    expect(costText(tester), '99');
  });

  group('save path', () {
    testWidgets('builds a record with trimmed provider and resolved currency', (
      tester,
    ) async {
      ServiceRecord? saved;
      await pumpDialog(tester, kindCost: 60, onSave: (r) async => saved = r);

      await tester.enterText(
        find.byKey(const Key('service-record-provider')),
        '  DiveShop Bonn  ',
      );
      await tester.enterText(find.byKey(costFieldKey), '75');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(saved, isNotNull);
      expect(saved!.provider, 'DiveShop Bonn');
      expect(saved!.cost, 75);
      expect(saved!.serviceKindId, 'scrubber-repack');
      // Currency came from the kind, upper-cased and never left blank: the
      // column is NOT NULL.
      expect(saved!.currency, 'EUR');
    });

    testWidgets('an empty provider is stored as null, not an empty string', (
      tester,
    ) async {
      ServiceRecord? saved;
      await pumpDialog(tester, onSave: (r) async => saved = r);

      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(saved!.provider, isNull);
    });

    testWidgets('a failing save surfaces the error and re-enables the form', (
      tester,
    ) async {
      await pumpDialog(
        tester,
        onSave: (_) async => throw Exception('write failed'),
      );

      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(find.textContaining('write failed'), findsOneWidget);
      // Still open, so the diver can retry rather than losing the entry.
      expect(find.text('Add Service Record'), findsOneWidget);
    });

    testWidgets('a negative cost fails validation and blocks the save', (
      tester,
    ) async {
      ServiceRecord? saved;
      await pumpDialog(tester, onSave: (r) async => saved = r);

      await tester.enterText(find.byKey(costFieldKey), '-1');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(saved, isNull);
    });

    testWidgets('the next service due date can be cleared', (tester) async {
      ServiceRecord? saved;
      final existing = ServiceRecord(
        id: 'r1',
        equipmentId: 'e1',
        serviceType: ServiceType.cleaning,
        serviceKindId: 'scrubber-repack',
        serviceDate: t0,
        nextServiceDue: DateTime(2026, 6, 14),
        createdAt: t0,
        updatedAt: t0,
      );
      await pumpDialog(
        tester,
        existingRecord: existing,
        onSave: (r) async => saved = r,
      );

      await tester.tap(find.byIcon(Icons.clear).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Update'));
      await tester.pumpAndSettle();

      expect(saved!.nextServiceDue, isNull);
    });
  });
}
