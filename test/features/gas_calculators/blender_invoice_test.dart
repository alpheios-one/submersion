import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/dive_log/domain/entities/dive.dart'
    show GasMix;
import 'package:submersion/features/gas_calculators/domain/blending/billed_fill.dart';
import 'package:submersion/features/gas_calculators/domain/blending/blender_preferences.dart';
import 'package:submersion/features/gas_calculators/presentation/providers/gas_blender_providers.dart';
import 'package:submersion/features/gas_calculators/presentation/widgets/blender/blender_billing_card.dart';
import 'package:submersion/features/gas_calculators/presentation/widgets/blender/blender_invoice_card.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

class _TestSettingsNotifier extends StateNotifier<AppSettings>
    implements SettingsNotifier {
  _TestSettingsNotifier(super.settings);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<WidgetRef> _pump(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(900, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  late WidgetRef captured;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsProvider.overrideWith(
          (ref) =>
              _TestSettingsNotifier(const AppSettings(defaultCurrency: 'CHF')),
        ),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: Consumer(
              builder: (context, ref, _) {
                captured = ref;
                return const Column(
                  children: [BlenderBillingCard(), BlenderInvoiceCard()],
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return captured;
}

void main() {
  group('BilledFill', () {
    test('round-trips through JSON, itemisation included', () {
      const fill = BilledFill(
        id: 'a',
        label: 'Tx 18/45',
        lines: [
          BilledGasLine(gas: 'O₂', addedBar: 10, cost: 10, freeGasLiters: 30),
          BilledGasLine(gas: 'He', addedBar: 80, cost: 20, freeGasLiters: 240),
        ],
        total: 35,
      );
      final decoded = BilledFill.fromJson(
        jsonDecode(jsonEncode(fill.toJson())) as Map<String, dynamic>,
      )!;
      expect(decoded.label, 'Tx 18/45');
      expect(decoded.lines, hasLength(2));
      expect(decoded.lines[1].gas, 'He');
      expect(decoded.lines[1].freeGasLiters, 240);
      expect(decoded.total, 35);
      expect(decoded.isManual, isFalse);
    });

    test('a line saved before #1335 has no volume, and that survives a '
        'round trip', () {
      const line = BilledGasLine(gas: 'O₂', addedBar: 10, cost: 10);
      final decoded = BilledGasLine.fromJson(
        jsonDecode(jsonEncode(line.toJson())) as Map<String, dynamic>,
      )!;
      expect(decoded.freeGasLiters, isNull);
    });

    test('a manual line has no itemisation', () {
      const fill = BilledFill(
        id: 'b',
        label: 'Analyser cell',
        lines: [],
        total: 40,
      );
      expect(fill.isManual, isTrue);
    });

    test('an unpriced line makes the total incomplete, not smaller', () {
      final total = totalOf(const [
        BilledFill(id: 'a', label: 'x', lines: [], total: 35),
        BilledFill(id: 'b', label: 'y', lines: [], total: null),
      ]);
      expect(total.amount, 35);
      expect(total.complete, isFalse);
    });

    test('preferences carry the bill through a round trip', () {
      final prefs = BlenderPreferences.defaults(cylinderWaterLiters: 12)
          .copyWith(
            billedFills: const [
              BilledFill(id: 'a', label: 'Tx 18/45', lines: [], total: 35),
            ],
            billedTo: 'Ada',
          );
      final decoded = BlenderPreferences.fromJson(
        jsonDecode(jsonEncode(prefs.toJson())) as Map<String, dynamic>,
      );
      expect(decoded.billedFills, hasLength(1));
      expect(decoded.billedFills.single.label, 'Tx 18/45');
      expect(decoded.billedTo, 'Ada');
    });

    test('billed fills are capped', () {
      final many = List.generate(
        BlenderPreferences.maxBilledFills + 5,
        (i) => BilledFill(id: '$i', label: 'x', lines: const [], total: 1),
      );
      final capped = BlenderPreferences.defaults(
        cylinderWaterLiters: 12,
      ).copyWith(billedFills: many);
      expect(capped.billedFills, hasLength(BlenderPreferences.maxBilledFills));
    });

    test('the invoice date and archived invoices round-trip through JSON', () {
      final date = DateTime(2026, 3, 5);
      final prefs = BlenderPreferences.defaults(cylinderWaterLiters: 12)
          .copyWith(
            billedDate: date,
            archivedInvoices: [
              ArchivedInvoice(
                id: 'inv-1',
                date: date,
                billedTo: 'Ada',
                fills: const [
                  BilledFill(id: 'a', label: 'Tx 18/45', lines: [], total: 35),
                ],
                total: 35,
              ),
            ],
          );
      final decoded = BlenderPreferences.fromJson(
        jsonDecode(jsonEncode(prefs.toJson())) as Map<String, dynamic>,
      );
      expect(decoded.billedDate, date);
      expect(decoded.archivedInvoices, hasLength(1));
      expect(decoded.archivedInvoices.single.billedTo, 'Ada');
      expect(decoded.archivedInvoices.single.fills.single.label, 'Tx 18/45');
      expect(decoded.archivedInvoices.single.total, 35);
    });

    test('a blob with no invoice date yet decodes to null, not a made-up '
        'date', () {
      final prefs = BlenderPreferences.defaults(cylinderWaterLiters: 12);
      final decoded = BlenderPreferences.fromJson(
        jsonDecode(jsonEncode(prefs.toJson())) as Map<String, dynamic>,
      );
      expect(decoded.billedDate, isNull);
    });

    test('an archived invoice keeps its currency snapshot through JSON, and '
        'an older one without it decodes to null rather than a made-up '
        'code', () {
      final withCurrency = ArchivedInvoice.fromJson(
        jsonDecode(
              jsonEncode(
                ArchivedInvoice(
                  id: 'a',
                  date: DateTime(2026, 3, 5),
                  billedTo: 'Ada',
                  fills: const [],
                  total: 35,
                  currencyCode: 'CHF',
                ).toJson(),
              ),
            )
            as Map<String, dynamic>,
      )!;
      expect(withCurrency.currencyCode, 'CHF');

      final withoutCurrency = ArchivedInvoice.fromJson({
        'id': 'b',
        'date': DateTime(2026, 3, 5).toIso8601String(),
        'billedTo': 'Ada',
        'fills': [],
        'total': 35,
      })!;
      expect(withoutCurrency.currencyCode, isNull);
    });

    test('archived invoices are capped, dropping the oldest', () {
      var invoices = <ArchivedInvoice>[];
      for (var i = 0; i < kMaxArchivedInvoices + 5; i++) {
        invoices = appendArchivedCapped(
          invoices,
          ArchivedInvoice(
            id: '$i',
            date: DateTime(2026, 1, 1),
            billedTo: '',
            fills: const [],
            total: 1,
          ),
        );
      }
      expect(invoices, hasLength(kMaxArchivedInvoices));
      expect(invoices.last.id, '${kMaxArchivedInvoices + 4}');
      expect(invoices.first.id, '5');
    });
  });

  group('invoice card', () {
    testWidgets('starts empty', (tester) async {
      await _pump(tester);
      expect(find.textContaining('Nothing billed yet'), findsOneWidget);
    });

    testWidgets('saving a fill puts it on the bill with its itemisation', (
      tester,
    ) async {
      final ref = await _pump(tester);
      ref.read(blenderCylinderLitersProvider.notifier).state = 3;
      ref.read(blenderTargetMixProvider.notifier).state = const GasMix(
        o2: 18,
        he: 45,
      );
      ref.read(blenderGasPricesProvider.notifier).state = const [
        2.0,
        10.0,
        0.1,
      ];
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('blender-save-fill')));
      await tester.pumpAndSettle();

      final fills = ref.read(blenderBilledFillsProvider);
      expect(fills, hasLength(1));
      expect(fills.single.label, 'Tx 18/45');
      expect(fills.single.lines, hasLength(3));
      expect(fills.single.total, isNotNull);
      expect(find.text('Tx 18/45'), findsWidgets);
      // The volume is frozen at save time (#1335), not just the pressure.
      expect(fills.single.lines.every((l) => l.freeGasLiters != null), isTrue);
    });

    testWidgets('two fills add up', (tester) async {
      final ref = await _pump(tester);
      ref.read(blenderBilledFillsProvider.notifier).state = const [
        BilledFill(id: 'a', label: 'Tx 18/45', lines: [], total: 35),
        BilledFill(id: 'b', label: 'Tx 15/55', lines: [], total: 35),
      ];
      await tester.pumpAndSettle();

      expect(totalOf(ref.read(blenderBilledFillsProvider)).amount, 70);
      expect(find.textContaining('70'), findsWidgets);
    });

    testWidgets('a line can be deleted', (tester) async {
      final ref = await _pump(tester);
      ref.read(blenderBilledFillsProvider.notifier).state = const [
        BilledFill(id: 'a', label: 'Tx 18/45', lines: [], total: 35),
      ];
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Delete Tx 18/45'));
      await tester.pumpAndSettle();

      expect(ref.read(blenderBilledFillsProvider), isEmpty);
    });

    testWidgets('a manual line can be added', (tester) async {
      final ref = await _pump(tester);
      await tester.tap(find.byKey(const Key('blender-add-manual-line')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('blender-line-description')),
        'Analyser cell',
      );
      await tester.enterText(
        find.byKey(const Key('blender-line-amount')),
        '12.50',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      final fills = ref.read(blenderBilledFillsProvider);
      expect(fills, hasLength(1));
      expect(fills.single.isManual, isTrue);
      expect(fills.single.total, closeTo(12.50, 0.001));
    });

    testWidgets('paying asks first, then archives and empties the bill', (
      tester,
    ) async {
      final ref = await _pump(tester);
      ref.read(blenderBilledToProvider.notifier).state = 'Ada';
      ref.read(blenderBilledFillsProvider.notifier).state = const [
        BilledFill(id: 'a', label: 'Tx 18/45', lines: [], total: 35),
      ];
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('blender-pay')));
      await tester.pumpAndSettle();
      expect(find.textContaining('archives all 1'), findsOneWidget);
      expect(ref.read(blenderBilledFillsProvider), hasLength(1));

      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(FilledButton, 'Pay'),
        ),
      );
      await tester.pumpAndSettle();
      expect(ref.read(blenderBilledFillsProvider), isEmpty);

      final archived = ref.read(blenderArchivedInvoicesProvider);
      expect(archived, hasLength(1));
      expect(archived.single.billedTo, 'Ada');
      expect(archived.single.fills.single.label, 'Tx 18/45');
      expect(archived.single.total, 35);
      // Snapshotted from the currency configured at the moment of paying, so
      // a later change to the default currency cannot silently relabel an
      // already-paid total.
      expect(archived.single.currencyCode, 'CHF');
    });

    testWidgets('an unpriced fill flags the total as incomplete', (
      tester,
    ) async {
      final ref = await _pump(tester);
      ref.read(blenderBilledFillsProvider.notifier).state = const [
        BilledFill(id: 'a', label: 'Tx 18/45', lines: [], total: 35),
        BilledFill(id: 'b', label: 'Tx 15/55', lines: [], total: null),
      ];
      await tester.pumpAndSettle();

      expect(find.textContaining('incomplete'), findsOneWidget);
    });

    testWidgets('the heading shows the invoice date, editable via the icon', (
      tester,
    ) async {
      final ref = await _pump(tester);
      final today = DateTime(2026, 3, 5);
      ref.read(blenderBilledDateProvider.notifier).state = today;
      await tester.pumpAndSettle();

      expect(find.textContaining('Mar 5, 2026'), findsOneWidget);
      expect(find.byKey(const Key('blender-billed-date-edit')), findsOneWidget);
    });

    testWidgets('a configured price shows up in the tariff summary', (
      tester,
    ) async {
      final ref = await _pump(tester);
      ref.read(blenderGasPricesProvider.notifier).state = const [
        1.2,
        null,
        null,
      ];
      await tester.pumpAndSettle();

      expect(find.textContaining('Current tariff'), findsOneWidget);
      expect(find.textContaining('1.20/100L'), findsOneWidget);
      // Unpriced banks are left out rather than shown as a placeholder.
      final tariffLine = tester
          .widgetList<Text>(find.byType(Text))
          .where((t) => t.data?.contains('Current tariff') ?? false)
          .single;
      expect(tariffLine.data, isNot(contains('null')));
    });

    testWidgets('no tariff line is shown when nothing is priced', (
      tester,
    ) async {
      await _pump(tester);
      expect(find.textContaining('Current tariff'), findsNothing);
    });

    testWidgets('a saved line with a volume shows litres, not pressure', (
      tester,
    ) async {
      final ref = await _pump(tester);
      ref.read(blenderBilledFillsProvider.notifier).state = const [
        BilledFill(
          id: 'a',
          label: 'Tx 18/45',
          lines: [
            BilledGasLine(gas: 'O₂', addedBar: 10, cost: 10, freeGasLiters: 30),
          ],
          total: 10,
        ),
      ];
      await tester.pumpAndSettle();

      expect(find.textContaining('30 L'), findsOneWidget);
    });

    testWidgets('an older line with no volume falls back to pressure', (
      tester,
    ) async {
      final ref = await _pump(tester);
      ref.read(blenderBilledFillsProvider.notifier).state = const [
        BilledFill(
          id: 'a',
          label: 'Tx 18/45',
          lines: [BilledGasLine(gas: 'O₂', addedBar: 10, cost: 10)],
          total: 10,
        ),
      ];
      await tester.pumpAndSettle();

      expect(find.textContaining('bar'), findsWidgets);
    });

    testWidgets('export and pay only appear once something is billed', (
      tester,
    ) async {
      await _pump(tester);
      expect(find.byKey(const Key('blender-export')), findsNothing);
      expect(find.byKey(const Key('blender-pay')), findsNothing);
    });
  });
  group('review findings', () {
    test('an amount can be cleared on an edited line', () {
      // Raised in review on PR #1215. Null marks a line as not yet priced,
      // which is what makes the grand total report itself incomplete, so
      // copyWith has to be able to express it.
      const fill = BilledFill(id: 'a', label: 'Tx 18/45', lines: [], total: 35);
      expect(fill.copyWith(label: 'x').total, 35);
      expect(fill.copyWith(clearTotal: true).total, isNull);
      expect(fill.copyWith(total: 40.0).total, 40.0);
    });

    test('appending past the cap drops the oldest, not the newest', () {
      var fills = <BilledFill>[];
      for (var i = 0; i < kMaxBilledFills + 5; i++) {
        fills = appendCapped(
          fills,
          BilledFill(id: '$i', label: 'fill $i', lines: const [], total: 1),
        );
      }
      expect(fills, hasLength(kMaxBilledFills));
      expect(fills.last.label, 'fill ${kMaxBilledFills + 4}');
      expect(fills.first.label, 'fill 5');
    });
  });
}
