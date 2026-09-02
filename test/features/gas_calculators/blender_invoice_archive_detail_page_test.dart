import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/gas_calculators/domain/blending/billed_fill.dart';
import 'package:submersion/features/gas_calculators/presentation/pages/blender_invoice_archive_detail_page.dart';
import 'package:submersion/features/gas_calculators/presentation/providers/gas_blender_providers.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

import '../../helpers/mock_providers.dart';

Future<void> _pump(
  WidgetTester tester, {
  required String invoiceId,
  List<ArchivedInvoice> invoices = const [],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsProvider.overrideWith(
          (ref) =>
              MockSettingsNotifier(const AppSettings(defaultCurrency: 'CHF')),
        ),
        blenderArchivedInvoicesProvider.overrideWith((ref) => invoices),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BlenderInvoiceArchiveDetailPage(invoiceId: invoiceId),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('BlenderInvoiceArchiveDetailPage', () {
    testWidgets('reports the invoice as not found for an unknown id', (
      tester,
    ) async {
      await _pump(tester, invoiceId: 'missing');
      expect(find.textContaining('Invoice not found'), findsOneWidget);
    });

    testWidgets(
      'shows the invoice date, billed-to, every itemised line and the total',
      (tester) async {
        await _pump(
          tester,
          invoiceId: 'inv-1',
          invoices: [
            ArchivedInvoice(
              id: 'inv-1',
              date: DateTime(2026, 3, 5),
              billedTo: 'Ada',
              fills: const [
                BilledFill(
                  id: 'f1',
                  label: 'Tx 18/45',
                  lines: [
                    BilledGasLine(
                      gas: 'O₂',
                      addedBar: 10,
                      cost: 10,
                      freeGasLiters: 30,
                    ),
                    BilledGasLine(gas: 'He', addedBar: 80, cost: 20),
                  ],
                  total: 30,
                ),
              ],
              total: 30,
              currencyCode: 'CHF',
            ),
          ],
        );

        expect(find.textContaining('Mar 5, 2026'), findsOneWidget);
        expect(find.textContaining('Billed to: Ada'), findsOneWidget);
        expect(find.text('Tx 18/45'), findsOneWidget);
        // The line saved with a volume shows litres...
        expect(find.textContaining('30 L'), findsOneWidget);
        // ...while the line saved before #1335 falls back to pressure.
        expect(find.textContaining('bar'), findsWidgets);
        expect(find.text('Total'), findsOneWidget);
      },
    );

    testWidgets('an unpriced invoice shows Incomplete instead of a total', (
      tester,
    ) async {
      await _pump(
        tester,
        invoiceId: 'inv-1',
        invoices: [
          ArchivedInvoice(
            id: 'inv-1',
            date: DateTime(2026, 3, 5),
            billedTo: '',
            fills: const [
              BilledFill(id: 'f1', label: 'Tx 18/45', lines: [], total: null),
            ],
            total: null,
          ),
        ],
      );

      expect(find.text('Incomplete'), findsOneWidget);
    });
  });
}
