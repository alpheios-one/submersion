import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/gas_calculators/presentation/widgets/gas_blender_calculator.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/features/tank_presets/presentation/providers/tank_preset_providers.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

import '../../helpers/test_app.dart';

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
        tankPresetsProvider.overrideWith((ref) async => const []),
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
  testWidgets('the gear opens the Trimix Mixer settings page', (tester) async {
    await _pump(tester);
    await tester.tap(find.byKey(const Key('blender-settings')));
    await tester.pumpAndSettle();

    expect(find.text('Trimix Mixer'), findsOneWidget);
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
    expect(find.byKey(const Key('blender-currency-display')), findsNothing);

    await tester.tap(find.byKey(const Key('blender-settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('blender-currency-display')), findsOneWidget);
  });

  testWidgets(
    'the cylinder-sizes link navigates to the global tank presets, not settings',
    (tester) async {
      late String location;
      final router = GoRouter(
        initialLocation: '/gas-calculators',
        routes: [
          GoRoute(
            path: '/gas-calculators',
            builder: (context, state) =>
                const Scaffold(body: GasBlenderCalculator()),
          ),
          GoRoute(
            path: '/tank-presets',
            builder: (context, state) {
              location = GoRouterState.of(context).uri.toString();
              return const Scaffold(body: Text('Tank Presets'));
            },
          ),
        ],
      );

      await tester.pumpWidget(
        testAppRouter(
          locale: const Locale('en'),
          router: router,
          overrides: [
            settingsProvider.overrideWith(
              (ref) => _TestSettingsNotifier(const AppSettings()),
            ),
            tankPresetsProvider.overrideWith((ref) async => const []),
          ],
        ),
      );
      await tester.pumpAndSettle();

      // The billing card sits below the fold on the default test surface, so
      // its link has to be scrolled into view before it can be tapped, same
      // as a diver would need to scroll down to reach it.
      await tester.ensureVisible(
        find.byKey(const Key('blender-cylinder-sizes-link')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('blender-cylinder-sizes-link')));
      await tester.pumpAndSettle();

      expect(location, '/tank-presets');
    },
  );
}
