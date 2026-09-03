import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/gas_calculators/domain/blending/billed_fill.dart';
import 'package:submersion/features/gas_calculators/presentation/gas_calculator_tools.dart';
import 'package:submersion/features/gas_calculators/presentation/providers/gas_blender_providers.dart';
import 'package:submersion/features/gas_calculators/presentation/widgets/blender/blender_invoice_archive_section.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';

import '../../helpers/mock_providers.dart';
import '../../helpers/test_app.dart';

ArchivedInvoice _invoice({
  required String id,
  required DateTime date,
  String billedTo = '',
  double? total = 35,
}) => ArchivedInvoice(
  id: id,
  date: date,
  billedTo: billedTo,
  fills: const [BilledFill(id: 'f', label: 'Tx 18/45', lines: [], total: 35)],
  total: total,
);

Future<WidgetRef> _pump(WidgetTester tester) async {
  late WidgetRef captured;
  await tester.pumpWidget(
    testApp(
      locale: const Locale('en'),
      overrides: [
        settingsProvider.overrideWith(
          (ref) =>
              MockSettingsNotifier(const AppSettings(defaultCurrency: 'CHF')),
        ),
      ],
      child: Consumer(
        builder: (context, ref, _) {
          captured = ref;
          return const BlenderInvoiceArchiveSection();
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  return captured;
}

Future<void> _expand(WidgetTester tester) async {
  await tester.tap(
    find.byKey(const Key('blender-invoice-archive-section-toggle')),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('BlenderInvoiceArchiveSection', () {
    testWidgets('renders nothing when nothing has been paid yet', (
      tester,
    ) async {
      await _pump(tester);
      expect(find.byType(Card), findsNothing);
    });

    testWidgets('is collapsed by default, hiding the invoice list', (
      tester,
    ) async {
      final ref = await _pump(tester);
      ref.read(blenderArchivedInvoicesProvider.notifier).state = [
        _invoice(id: 'a', date: DateTime(2026, 3, 5), billedTo: 'Ada'),
      ];
      await tester.pumpAndSettle();

      expect(find.text('Ada'), findsNothing);

      await _expand(tester);
      expect(find.text('Ada'), findsOneWidget);
    });

    testWidgets(
      'buckets by year+month and preselects the newest month when all '
      'invoices fall in one year',
      (tester) async {
        final ref = await _pump(tester);
        ref.read(blenderArchivedInvoicesProvider.notifier).state = [
          _invoice(id: 'a', date: DateTime(2026, 1, 10), billedTo: 'January'),
          _invoice(id: 'b', date: DateTime(2026, 3, 5), billedTo: 'March'),
        ];
        await tester.pumpAndSettle();
        await _expand(tester);

        // Newest month (March) is preselected, so only that invoice shows.
        expect(find.text('March'), findsOneWidget);
        expect(find.text('January'), findsNothing);
        expect(find.text('March 2026'), findsOneWidget);
      },
    );

    testWidgets(
      'buckets by year and preselects the newest year when invoices span '
      'more than one year',
      (tester) async {
        final ref = await _pump(tester);
        ref.read(blenderArchivedInvoicesProvider.notifier).state = [
          _invoice(id: 'a', date: DateTime(2025, 12, 1), billedTo: 'Old'),
          _invoice(id: 'b', date: DateTime(2026, 1, 5), billedTo: 'New'),
        ];
        await tester.pumpAndSettle();
        await _expand(tester);

        expect(find.text('New'), findsOneWidget);
        expect(find.text('Old'), findsNothing);
        expect(find.text('2026'), findsOneWidget);
      },
    );

    testWidgets('switching the period dropdown narrows the list', (
      tester,
    ) async {
      final ref = await _pump(tester);
      ref.read(blenderArchivedInvoicesProvider.notifier).state = [
        _invoice(id: 'a', date: DateTime(2025, 12, 1), billedTo: 'Old'),
        _invoice(id: 'b', date: DateTime(2026, 1, 5), billedTo: 'New'),
      ];
      await tester.pumpAndSettle();
      await _expand(tester);

      expect(find.text('New'), findsOneWidget);
      expect(find.text('Old'), findsNothing);

      await tester.tap(find.text('2026'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('2025').last);
      await tester.pumpAndSettle();

      expect(find.text('Old'), findsOneWidget);
      expect(find.text('New'), findsNothing);
    });

    testWidgets('tapping an invoice opens its detail route', (tester) async {
      final router = GoRouter(
        initialLocation: '/planning/gas-calculators/blender',
        routes: [
          GoRoute(
            path: '/planning/gas-calculators/blender',
            builder: (context, state) =>
                const Scaffold(body: BlenderInvoiceArchiveSection()),
          ),
          GoRoute(
            path: '$kBlenderInvoiceArchiveRoute/:invoiceId',
            builder: (context, state) => Scaffold(
              body: Text('detail-${state.pathParameters['invoiceId']}'),
            ),
          ),
        ],
      );

      await tester.pumpWidget(
        testAppRouter(
          router: router,
          overrides: [
            settingsProvider.overrideWith(
              (ref) => MockSettingsNotifier(
                const AppSettings(defaultCurrency: 'CHF'),
              ),
            ),
            blenderArchivedInvoicesProvider.overrideWith(
              (ref) => [
                _invoice(
                  id: 'inv-1',
                  date: DateTime(2026, 1, 1),
                  billedTo: 'Ada',
                ),
              ],
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await _expand(tester);

      await tester.tap(find.text('Ada'));
      await tester.pumpAndSettle();

      expect(find.text('detail-inv-1'), findsOneWidget);
    });
  });
}
