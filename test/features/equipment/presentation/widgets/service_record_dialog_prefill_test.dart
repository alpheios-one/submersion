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
              onSave: (record) async {},
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
}
