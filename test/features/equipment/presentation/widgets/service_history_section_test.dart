import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:submersion/core/constants/enums.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/equipment/domain/entities/service_kind.dart';
import 'package:submersion/features/equipment/domain/entities/service_record.dart';
import 'package:submersion/features/equipment/presentation/providers/equipment_providers.dart';
import 'package:submersion/features/equipment/presentation/widgets/service_history_section.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

import '../../../../helpers/mock_providers.dart';

void main() {
  final t0 = DateTime(2026, 1, 1);
  const equipmentId = 'e1';

  ServiceKind kind(String id, String name) =>
      ServiceKind(id: id, name: name, createdAt: t0, updatedAt: t0);

  ServiceRecord record({
    required String id,
    String? kindId,
    ServiceType type = ServiceType.cleaning,
    DateTime? date,
    double? cost,
    String? provider,
    DateTime? nextDue,
    String notes = '',
  }) {
    final when = date ?? DateTime(2026, 3, 14);
    return ServiceRecord(
      id: id,
      equipmentId: equipmentId,
      serviceType: type,
      serviceKindId: kindId,
      serviceDate: when,
      provider: provider,
      cost: cost,
      currency: 'EUR',
      nextServiceDue: nextDue,
      notes: notes,
      createdAt: when,
      updatedAt: when,
    );
  }

  Future<void> pumpSection(
    WidgetTester tester, {
    required List<ServiceRecord> records,
    required List<ServiceKind> kinds,
    Locale locale = const Locale('en'),
    Size surface = const Size(600, 1200),
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = surface;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final overrides = await getBaseOverrides();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...overrides,
          serviceKindsProvider.overrideWith((ref) async => kinds),
          serviceRecordNotifierProvider(
            equipmentId,
          ).overrideWith((ref) => _MockServiceRecordNotifier(records)),
          serviceRecordTotalCostProvider(
            equipmentId,
          ).overrideWith((ref) async => <String, double>{}),
        ].cast(),
        child: MaterialApp(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: SingleChildScrollView(
              child: ServiceHistorySection(equipmentId: equipmentId),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('row titles with the maintenance task name', (tester) async {
    await pumpSection(
      tester,
      records: [record(id: 'r1', kindId: 'scrubber-repack')],
      kinds: [kind('scrubber-repack', 'Scrubber repack')],
    );

    expect(find.text('Scrubber repack'), findsOneWidget);
  });

  testWidgets('row falls back to the localized type when untagged', (
    tester,
  ) async {
    await pumpSection(
      tester,
      records: [record(id: 'r1', type: ServiceType.cleaning)],
      kinds: const [],
      locale: const Locale('de'),
    );

    expect(find.text('Reinigung'), findsOneWidget);
  });

  testWidgets('row renders notes and next due', (tester) async {
    await pumpSection(
      tester,
      records: [
        record(
          id: 'r1',
          kindId: 'scrubber-repack',
          notes: 'Packed 2.4kg',
          nextDue: DateTime(2026, 6, 14),
        ),
      ],
      kinds: [kind('scrubber-repack', 'Scrubber repack')],
    );

    expect(find.textContaining('Packed 2.4kg'), findsOneWidget);
    expect(find.textContaining('Next due'), findsOneWidget);
  });

  testWidgets('a long German task name keeps its title width', (tester) async {
    // Regression for the issue #935 class: a text-bearing ListTile.trailing is
    // laid out against the full tile width first, starving the title to near
    // zero. Flutter's guard is assert-only, so a release build renders one
    // glyph per line instead of throwing. find.text + findsOneWidget passes
    // happily in that state, so the assertion must be on rendered width.
    const longName = 'Sauerstoffsensor ersetzen und kalibrieren';
    await pumpSection(
      tester,
      records: [record(id: 'r1', kindId: 'o2-cell', cost: 129.99)],
      kinds: [kind('o2-cell', longName)],
      locale: const Locale('de'),
      surface: const Size(360, 800),
    );

    expect(tester.getSize(find.text(longName)).width, greaterThan(150));
  });
}

class _MockServiceRecordNotifier
    extends StateNotifier<AsyncValue<List<ServiceRecord>>>
    implements ServiceRecordNotifier {
  _MockServiceRecordNotifier(List<ServiceRecord> records)
    : super(AsyncValue.data(records));

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
