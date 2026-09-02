import 'dart:async';

import 'package:flutter/material.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/features/dive_log/data/services/profile_analysis_service.dart';
import 'package:submersion/features/dive_log/domain/entities/dive.dart';
import 'package:submersion/features/dive_log/domain/entities/dive_data_source.dart';
import 'package:submersion/features/dive_log/domain/entities/gas_switch.dart';
import 'package:submersion/features/dive_log/domain/entities/source_profile.dart';
import 'package:submersion/features/dive_log/presentation/pages/dive_detail_page.dart';
import 'package:submersion/features/dive_log/presentation/providers/dive_providers.dart';
import 'package:submersion/features/dive_log/presentation/providers/gas_switch_providers.dart';
import 'package:submersion/features/dive_log/presentation/providers/profile_analysis_provider.dart';
import 'package:submersion/features/dive_log/presentation/widgets/dive_profile_chart.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

import '../../../../helpers/mock_providers.dart';

/// Regression cover for the one-time profile chart flash on first open.
///
/// Opening a dive for the first time computes and persists its safety
/// review. That write ticks `watchDiveDetailChanges` about 300ms after the
/// chart has painted, which refreshes `diveProvider`. Providers that watch
/// `diveProvider`'s future (`estimatedTankPressuresProvider`) go through a
/// RELOAD behind it, and the same happens to the analysis chain whenever one
/// of its inputs refreshes. The profile section read every chart input
/// through the `valueOrNull` polyfill, which returns null during a reload, so
/// the chart dropped the series for a frame and then drew it again.
///
/// The built-in `AsyncValue.value` keeps the previous value across a reload;
/// these tests pin that the chart is fed from it.
void main() {
  Dive diveWithProfileAndTank() => createTestDiveWithBottomTime().copyWith(
    profile: List.generate(
      6,
      (i) => DiveProfilePoint(
        timestamp: i * 60,
        depth: (i < 3 ? i * 8.0 : (5 - i) * 8.0),
      ),
    ),
    // Start/end pressures but no transmitter samples: exactly the shape the
    // estimated pressure synthesizer fills in.
    tanks: const [
      DiveTank(id: 'tank-1', volume: 11.1, startPressure: 200, endPressure: 60),
    ],
  );

  ProfileAnalysis analysisWithCeiling() => ProfileAnalysis.empty().copyWith(
    ceilingCurve: List<double>.filled(6, 0.0),
  );

  Future<ProviderContainer> pumpDetail(
    WidgetTester tester, {
    required Dive dive,
    required Override diveOverride,
    required Override analysisOverride,
  }) async {
    final base = await getBaseOverrides();
    // The detail page overflows the fixed test viewport; that is not what
    // these tests assert.
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
          diveOverride,
          analysisOverride,
          diveDataSourcesProvider(
            dive.id,
          ).overrideWith((ref) async => <DiveDataSource>[]),
          gasSwitchesProvider(
            dive.id,
          ).overrideWith((ref) async => <GasSwitchWithTank>[]),
          // No real samples, so estimatedTankPressuresProvider (deliberately
          // NOT overridden) synthesizes a series for tank-1.
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
    return ProviderScope.containerOf(
      tester.element(find.byType(DiveDetailPage)),
    );
  }

  DiveProfileChart chart(WidgetTester tester) =>
      tester.widget<DiveProfileChart>(find.byType(DiveProfileChart));

  testWidgets(
    'keeps the estimated pressure series while the dive provider refreshes',
    (tester) async {
      final dive = diveWithProfileAndTank();
      // Held open once the refresh starts so the reload window spans a frame.
      Completer<void>? diveGate;
      final container = await pumpDetail(
        tester,
        dive: dive,
        diveOverride: diveProvider(dive.id).overrideWith((ref) async {
          final gate = diveGate;
          if (gate != null) await gate.future;
          return dive;
        }),
        analysisOverride: profileAnalysisProvider(
          dive.id,
        ).overrideWith((ref) async => analysisWithCeiling()),
      );

      expect(chart(tester).estimatedTankIds, contains('tank-1'));
      expect(chart(tester).tankPressures?['tank-1'], isNotEmpty);

      // The detail change tick: diveProvider refreshes and, behind it,
      // estimatedTankPressuresProvider reloads.
      diveGate = Completer<void>();
      container.invalidate(diveProvider(dive.id));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        container.read(estimatedTankPressuresProvider(dive.id)).isReloading,
        isTrue,
        reason: 'precondition: the estimate must be mid-reload',
      );
      expect(
        chart(tester).estimatedTankIds,
        contains('tank-1'),
        reason:
            'a reload of the estimate must not drop the series from the '
            'chart; the previous value is still available',
      );
      expect(chart(tester).tankPressures?['tank-1'], isNotEmpty);

      diveGate.complete();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(chart(tester).estimatedTankIds, contains('tank-1'));
    },
  );

  testWidgets('keeps the analysis overlays while the analysis reloads', (
    tester,
  ) async {
    final dive = diveWithProfileAndTank();
    final analysis = analysisWithCeiling();
    // Flipping the trigger reloads the analysis; the gate holds that reload
    // open so it spans a frame.
    final trigger = StateProvider<int>((ref) => 0);
    Completer<ProfileAnalysis?>? analysisGate;
    final container = await pumpDetail(
      tester,
      dive: dive,
      diveOverride: diveProvider(dive.id).overrideWith((ref) async => dive),
      analysisOverride: profileAnalysisProvider(dive.id).overrideWith((
        ref,
      ) async {
        if (ref.watch(trigger) == 0) return analysis;
        return analysisGate!.future;
      }),
    );

    expect(chart(tester).ceilingCurve, isNotNull);

    analysisGate = Completer<ProfileAnalysis?>();
    container.read(trigger.notifier).state = 1;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      container
          .read(
            sourceProfileAnalysisProvider((diveId: dive.id, sourceId: null)),
          )
          .isLoading,
      isTrue,
      reason: 'precondition: the analysis must be mid-reload',
    );
    expect(
      chart(tester).ceilingCurve,
      isNotNull,
      reason:
          'a reload of the analysis must not strip the overlays from the '
          'chart; the previous analysis is still available',
    );

    analysisGate.complete(analysis);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(chart(tester).ceilingCurve, isNotNull);
  });
}
