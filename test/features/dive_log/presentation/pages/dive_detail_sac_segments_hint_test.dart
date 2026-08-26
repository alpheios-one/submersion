import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/constants/enums.dart';
import 'package:submersion/core/constants/units.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/dive_log/data/services/profile_analysis_service.dart';
import 'package:submersion/features/dive_log/domain/entities/dive.dart';
import 'package:submersion/features/dive_log/domain/entities/dive_data_source.dart';
import 'package:submersion/features/dive_log/domain/entities/gas_switch.dart';
import 'package:submersion/features/dive_log/domain/entities/source_profile.dart';
import 'package:submersion/features/dive_log/presentation/pages/dive_detail_page.dart';
import 'package:submersion/features/dive_log/presentation/providers/dive_providers.dart';
import 'package:submersion/features/dive_log/presentation/providers/gas_analysis_providers.dart';
import 'package:submersion/features/dive_log/presentation/providers/gas_switch_providers.dart';
import 'package:submersion/features/dive_log/presentation/providers/profile_analysis_provider.dart';
import 'package:submersion/features/dive_log/presentation/widgets/collapsible_section.dart';
import 'package:submersion/features/dive_log/presentation/widgets/sac_volume_hint.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

import '../../../../helpers/mock_providers.dart';

/// The SAC-by-segment card converts its bar/min segments to L/min with the
/// dive's cylinder volume. Without one it silently showed bar/min under an
/// L/min preference (issue #386); now it says so.
void main() {
  Dive diveWithProfile({double? tankVolume}) {
    return createTestDiveWithBottomTime().copyWith(
      profile: List.generate(
        6,
        (i) => DiveProfilePoint(
          timestamp: i * 60,
          depth: (i < 3 ? i * 8.0 : (5 - i) * 8.0),
        ),
      ),
      tanks: [
        DiveTank(
          id: 'tank-1',
          volume: tankVolume,
          startPressure: 200.0,
          endPressure: 50.0,
          gasMix: const GasMix(),
          role: TankRole.backGas,
        ),
      ],
    );
  }

  ProfileAnalysis analysisWithSacSegments() {
    return ProfileAnalysis.empty().copyWith(
      sacSegments: const [
        SacSegment(
          startTimestamp: 0,
          endTimestamp: 300,
          avgDepth: 18.0,
          minDepth: 0.0,
          maxDepth: 24.0,
          sacRate: 0.8,
          gasConsumed: 4.0,
          segmentationType: SacSegmentationType.timeInterval,
        ),
      ],
    );
  }

  Future<void> pumpWith(
    WidgetTester tester, {
    required Dive dive,
    required AppSettings settings,
  }) async {
    final base = await getBaseOverrides(
      settingsNotifier: MockSettingsNotifier(settings),
    );
    final originalOnError = FlutterError.onError;
    addTearDown(() => FlutterError.onError = originalOnError);
    FlutterError.onError = (d) {
      if (d.toString().contains('overflowed')) return;
      originalOnError?.call(d);
    };

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...base,
          diveProvider(dive.id).overrideWith((ref) async => dive),
          diveDataSourcesProvider(
            dive.id,
          ).overrideWith((ref) async => <DiveDataSource>[]),
          profileAnalysisProvider(
            dive.id,
          ).overrideWith((ref) async => analysisWithSacSegments()),
          selectedSegmentationProvider.overrideWith(
            (ref) => SacSegmentationType.timeInterval,
          ),
          gasSwitchesProvider(
            dive.id,
          ).overrideWith((ref) async => <GasSwitchWithTank>[]),
          tankPressuresProvider(
            dive.id,
          ).overrideWith((ref) async => <String, List<TankPressurePoint>>{}),
          sourceProfilesProvider(
            dive.id,
          ).overrideWith((ref) async => <String, SourceProfile>{}),
          weeklyOtuProvider(dive.id).overrideWith((ref) async => 0.0),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DiveDetailPage(diveId: dive.id, embedded: true),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  Finder hintInSacCard(WidgetTester tester) {
    final l10n = AppLocalizations.of(
      tester.element(find.byType(DiveDetailPage)),
    );
    final card = find.widgetWithText(
      CollapsibleCardSection,
      l10n.diveLog_detail_section_sacRateBySegment,
    );
    expect(card, findsOneWidget);
    return find.descendant(of: card, matching: find.byType(SacVolumeHint));
  }

  testWidgets('explains the bar/min fallback when L/min is selected', (
    tester,
  ) async {
    await pumpWith(
      tester,
      dive: diveWithProfile(),
      settings: const AppSettings(sacUnit: SacUnit.litersPerMin),
    );

    expect(hintInSacCard(tester), findsOneWidget);
  });

  testWidgets('shows no hint once the cylinder has a volume', (tester) async {
    await pumpWith(
      tester,
      dive: diveWithProfile(tankVolume: 12.0),
      settings: const AppSettings(sacUnit: SacUnit.litersPerMin),
    );

    expect(hintInSacCard(tester), findsNothing);
  });

  testWidgets('shows no hint under a pressure-per-minute preference', (
    tester,
  ) async {
    await pumpWith(
      tester,
      dive: diveWithProfile(),
      settings: const AppSettings(sacUnit: SacUnit.pressurePerMin),
    );

    expect(hintInSacCard(tester), findsNothing);
  });
}
