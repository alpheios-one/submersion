import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/gas_calculators/presentation/widgets/gas_blender_calculator.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

class _TestSettingsNotifier extends StateNotifier<AppSettings>
    implements SettingsNotifier {
  _TestSettingsNotifier(super.settings);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _pump(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsProvider.overrideWith(
          (ref) => _TestSettingsNotifier(const AppSettings()),
        ),
      ],
      child: const MaterialApp(
        locale: Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: GasBlenderCalculator()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the gear opens the settings page', (tester) async {
    await _pump(tester);
    await tester.tap(find.byKey(const Key('blender-settings')));
    await tester.pumpAndSettle();

    expect(find.text('Fill gases'), findsOneWidget);
    expect(find.text('Blending conditions'), findsOneWidget);
    expect(find.text('Default settings and billing'), findsOneWidget);
  });

  testWidgets('fill gases and mixing conditions leave the main screen', (
    tester,
  ) async {
    // Issue #1335: they move behind the gear, keeping their own layout, so
    // they no longer compete with the fields a diver retypes every fill.
    await _pump(tester);
    expect(find.text('Fill gases'), findsNothing);
    expect(find.text('Blending conditions'), findsNothing);
  });

  testWidgets('the currency and price fields leave the billing card', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.byKey(const Key('blender-currency')), findsNothing);

    await tester.tap(find.byKey(const Key('blender-settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('blender-currency')), findsOneWidget);
  });

  testWidgets('the cylinder template manager lives in settings', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(find.byKey(const Key('blender-settings')));
    await tester.pumpAndSettle();

    expect(find.text('Cylinder sizes'), findsOneWidget);
    // Seeded with the blending-bench sizes named in issue #1100, not empty
    // (issue #1335 follow-up: this is now the dropdown's only source).
    expect(find.text('AL80'), findsOneWidget);
  });

  testWidgets('the billing card gear also opens settings, scrolled down', (
    tester,
  ) async {
    await _pump(tester);
    // The billing card sits below the fold on the default test surface, so
    // its gear has to be scrolled into view before it can be tapped, same
    // as a diver would need to scroll down to reach it.
    await tester.ensureVisible(
      find.byKey(const Key('blender-billing-settings')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('blender-billing-settings')));
    await tester.pumpAndSettle();

    expect(find.text('Default settings and billing'), findsOneWidget);
  });
}
