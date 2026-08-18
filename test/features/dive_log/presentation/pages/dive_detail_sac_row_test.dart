import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:submersion/core/constants/enums.dart';
import 'package:submersion/core/constants/gas_model.dart';
import 'package:submersion/core/constants/units.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/dive_log/domain/entities/dive.dart';
import 'package:submersion/features/dive_log/presentation/pages/dive_detail_page.dart';
import 'package:submersion/features/dive_log/presentation/providers/dive_providers.dart';
import 'package:submersion/features/divers/presentation/providers/diver_providers.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

import '../../../../helpers/mock_providers.dart';

/// The dive detail SAC row honors the gas model preference (issue #828).
///
/// The volumetric lane is the only one that can differ; bar/min is a pressure
/// drop and carries no equation of state.
void main() {
  /// The issue's cylinder: 12 L, 200 -> 50 bar, 44 min, 13.2 m average.
  /// Ideal reads 17.6 L/min, real reads 16.8.
  Dive reportedDive() {
    return createTestDiveWithBottomTime(
      runtime: const Duration(minutes: 44),
      avgDepth: 13.2,
    ).copyWith(
      tanks: const [
        DiveTank(
          id: 'tank-1',
          volume: 12.0,
          startPressure: 200.0,
          endPressure: 50.0,
          gasMix: GasMix(o2: 21.0, he: 0.0),
          role: TankRole.backGas,
        ),
      ],
    );
  }

  Future<void> pumpWith(WidgetTester tester, AppSettings settings) async {
    final dive = reportedDive();
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          settingsProvider.overrideWith(
            (ref) => MockSettingsNotifier(settings),
          ),
          currentDiverIdProvider.overrideWith(
            (ref) => MockCurrentDiverIdNotifier(),
          ),
          diveProvider(dive.id).overrideWith((ref) async => dive),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DiveDetailPage(diveId: dive.id, embedded: true),
        ),
      ),
    );

    // The detail page renders a profile chart that can overflow an
    // unconstrained test viewport; swallow layout errors so this stays
    // scoped to the SAC row, matching the sibling detail-page tests.
    final originalOnError = FlutterError.onError;
    FlutterError.onError = (_) {};
    addTearDown(() => FlutterError.onError = originalOnError);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('volumetric SAC reads the ideal value when ideal is selected', (
    tester,
  ) async {
    await pumpWith(
      tester,
      const AppSettings(
        sacUnit: SacUnit.litersPerMin,
        gasModel: GasModel.ideal,
      ),
    );

    expect(find.text('17.6 L/min'), findsOneWidget);
  });

  testWidgets('volumetric SAC reads the real value when real is selected', (
    tester,
  ) async {
    await pumpWith(
      tester,
      const AppSettings(sacUnit: SacUnit.litersPerMin, gasModel: GasModel.real),
    );

    expect(find.text('16.8 L/min'), findsOneWidget);
  });

  testWidgets('the pressure lane ignores the gas model', (tester) async {
    for (final model in GasModel.values) {
      await pumpWith(
        tester,
        AppSettings(sacUnit: SacUnit.pressurePerMin, gasModel: model),
      );
      // 150 bar / 44 min / 2.32 bar ambient = 1.47 bar/min, whichever
      // equation of state is selected.
      expect(find.text('1.5 bar/min'), findsOneWidget);
    }
  });
}
