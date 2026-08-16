import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// `show Intl`: intl also exports a TextDirection that shadows dart:ui's enum.
import 'package:intl/intl.dart' show Intl;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:submersion/core/constants/units.dart';
import 'package:submersion/features/dive_3d/domain/spatial/seascape_appearance.dart';
import 'package:submersion/features/dive_3d/presentation/widgets/terrain_appearance_sheet.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

import '../../../../helpers/mock_providers.dart';

void main() {
  /// The custom-level rows own their controllers, so the on-screen text is
  /// read from the controller rather than from a one-shot `initialValue`.
  String levelFieldText(WidgetTester tester, int index) => tester
      .widget<TextField>(find.byKey(ValueKey('seascapeLevelField$index')))
      .controller!
      .text;

  String? levelFieldSuffix(WidgetTester tester, int index) => tester
      .widget<TextField>(find.byKey(ValueKey('seascapeLevelField$index')))
      .decoration
      ?.suffixText;

  const twoLevels = AppSettings(
    seascapeAppearance: SeascapeAppearance(
      contourMode: SeascapeContourMode.custom,
      customLevels: [
        SeascapeContourLevel(depthMeters: 20),
        SeascapeContourLevel(depthMeters: 30),
      ],
    ),
  );

  /// The reporter's list: enough rows that the sheet has to scroll.
  final manyLevels = AppSettings(
    seascapeAppearance: SeascapeAppearance(
      contourMode: SeascapeContourMode.custom,
      customLevels: [
        for (var d = 10; d <= 100; d += 10)
          SeascapeContourLevel(depthMeters: d.toDouble()),
      ],
    ),
  );

  Future<ProviderContainer> pumpSheet(
    WidgetTester tester, {
    AppSettings initial = const AppSettings(),
  }) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        settingsProvider.overrideWith((ref) => MockSettingsNotifier(initial)),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          locale: Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(child: TerrainAppearanceSheet()),
          ),
        ),
      ),
    );
    await tester.pump();
    return container;
  }

  /// Pumps the sheet through its real modal route, which is where the
  /// keyboard inset and the dismissal commit live.
  Future<ProviderContainer> pumpSheetRoute(
    WidgetTester tester, {
    AppSettings initial = const AppSettings(),
  }) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        settingsProvider.overrideWith((ref) => MockSettingsNotifier(initial)),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showTerrainAppearanceSheet(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('banded switch writes through to settings', (tester) async {
    final container = await pumpSheet(tester);
    expect(
      container.read(settingsProvider).seascapeAppearance.rampBanded,
      isFalse,
    );
    await tester.tap(find.byKey(const ValueKey('seascapeBandedSwitch')));
    await tester.pump();
    expect(
      container.read(settingsProvider).seascapeAppearance.rampBanded,
      isTrue,
    );
  });

  testWidgets('ramp range toggle seeds a default max and clears it', (
    tester,
  ) async {
    final container = await pumpSheet(tester);
    await tester.tap(find.byKey(const ValueKey('seascapeRampRangeSwitch')));
    await tester.pump();
    expect(
      container.read(settingsProvider).seascapeAppearance.rampMaxDepthMeters,
      40.0,
    );
    await tester.tap(find.byKey(const ValueKey('seascapeRampRangeSwitch')));
    await tester.pump();
    expect(
      container.read(settingsProvider).seascapeAppearance.rampMaxDepthMeters,
      isNull,
    );
  });

  testWidgets('custom mode adds a level via the add button', (tester) async {
    final container = await pumpSheet(tester);
    await tester.tap(find.text('Custom'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('seascapeAddLevelButton')));
    await tester.pump();
    final appearance = container.read(settingsProvider).seascapeAppearance;
    expect(appearance.contourMode, SeascapeContourMode.custom);
    expect(appearance.customLevels, hasLength(1));
    expect(appearance.customLevels.single.depthMeters, 10.0);
  });

  testWidgets('a feet diver gets a round seed in their own unit', (
    tester,
  ) async {
    // The editor shows display units, so seeding a fixed 10 m would read as
    // 32.8 ft. The seed is 10 DISPLAY units, stored as meters underneath.
    final container = await pumpSheet(
      tester,
      initial: const AppSettings(depthUnit: DepthUnit.feet),
    );
    await tester.tap(find.text('Custom'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('seascapeAddLevelButton')));
    await tester.pump();
    final level = container
        .read(settingsProvider)
        .seascapeAppearance
        .customLevels
        .single;
    expect(level.depthMeters, closeTo(3.048, 1e-9)); // 10 ft
    // The row's field reads the round display value, not 32.8.
    expect(levelFieldText(tester, 0), '10');
  });

  testWidgets('surface mode segmented control writes through', (tester) async {
    final container = await pumpSheet(tester);
    expect(
      container.read(settingsProvider).seascapeAppearance.surfaceMode,
      SeascapeSurfaceMode.depth,
    );
    await tester.tap(find.text('Map imagery'));
    await tester.pump();
    expect(
      container.read(settingsProvider).seascapeAppearance.surfaceMode,
      SeascapeSurfaceMode.imagery,
    );
    await tester.tap(find.text('Blend'));
    await tester.pump();
    expect(
      container.read(settingsProvider).seascapeAppearance.surfaceMode,
      SeascapeSurfaceMode.blend,
    );
  });

  testWidgets('wall angle slider persists its value', (tester) async {
    final container = await pumpSheet(tester);
    final slider = find.byKey(const ValueKey('seascapeWallAngleSlider'));
    await tester.drag(slider, const Offset(200, 0));
    await tester.pump();
    expect(
      container.read(settingsProvider).seascapeAppearance.wallAngleDeg,
      greaterThan(22.0),
    );
  });

  // Issue #1094: a decimal keypad has no submit key, so requiring
  // onFieldSubmitted meant every typed level was silently discarded.
  group('custom level editing (issue #1094)', () {
    List<SeascapeContourLevel> levelsOf(ProviderContainer c) =>
        c.read(settingsProvider).seascapeAppearance.customLevels;

    testWidgets('a typed level is adopted when the field loses focus', (
      tester,
    ) async {
      final container = await pumpSheet(tester, initial: twoLevels);
      await tester.enterText(
        find.byKey(const ValueKey('seascapeLevelField0')),
        '35',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(levelsOf(container).first.depthMeters, 35.0);
    });

    testWidgets('a feet diver has the typed level stored as meters', (
      tester,
    ) async {
      final container = await pumpSheet(
        tester,
        initial: twoLevels.copyWith(depthUnit: DepthUnit.feet),
      );
      await tester.enterText(
        find.byKey(const ValueKey('seascapeLevelField0')),
        '100',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(levelsOf(container).first.depthMeters, closeTo(30.48, 1e-9));
    });

    testWidgets('unparseable text reverts to the stored level', (tester) async {
      final container = await pumpSheet(tester, initial: twoLevels);
      await tester.enterText(
        find.byKey(const ValueKey('seascapeLevelField0')),
        'abc',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(levelsOf(container).first.depthMeters, 20.0);
      expect(levelFieldText(tester, 0), '20');
    });

    testWidgets('a pending edit is adopted when the sheet is dismissed', (
      tester,
    ) async {
      // Closing the keyboard with the system back gesture leaves the field
      // focused, so dismissal is the last chance to keep the diver's number.
      final container = await pumpSheetRoute(tester, initial: twoLevels);
      await tester.enterText(
        find.byKey(const ValueKey('seascapeLevelField0')),
        '45',
      );
      await tester.pump();
      Navigator.of(tester.element(find.byType(TerrainAppearanceSheet))).pop();
      await tester.pumpAndSettle();
      expect(levelsOf(container).first.depthMeters, 45.0);
    });

    testWidgets('deleting a row re-seeds the rows that shift up', (
      tester,
    ) async {
      // The rows are keyed by index, so without a re-seed row 0 would keep
      // showing the deleted level's number.
      final container = await pumpSheet(tester, initial: twoLevels);
      await tester.tap(find.byKey(const ValueKey('seascapeLevelRemove0')));
      await tester.pump();
      expect(levelsOf(container).single.depthMeters, 30.0);
      expect(levelFieldText(tester, 0), '30');
    });

    testWidgets('switching depth unit re-seeds the row text', (tester) async {
      final container = await pumpSheet(tester, initial: twoLevels);
      await container
          .read(settingsProvider.notifier)
          .setDepthUnit(DepthUnit.feet);
      await tester.pump();
      expect(levelFieldText(tester, 0), '65.6'); // 20 m
    });

    testWidgets('a de diver dismissing an untouched sheet changes nothing', (
      tester,
    ) async {
      // The reporter is on a comma-decimal locale, and the new commit-on-
      // dismissal path is where a seed/parse mismatch would silently rescale
      // an untouched level. Feet display puts a fraction in every box.
      final previous = Intl.defaultLocale;
      Intl.defaultLocale = 'de';
      addTearDown(() => Intl.defaultLocale = previous);
      final container = await pumpSheetRoute(
        tester,
        initial: twoLevels.copyWith(depthUnit: DepthUnit.feet),
      );
      expect(levelFieldText(tester, 0), '65.6'); // 20 m in feet
      Navigator.of(tester.element(find.byType(TerrainAppearanceSheet))).pop();
      await tester.pumpAndSettle();
      expect(levelsOf(container).map((l) => l.depthMeters), [
        closeTo(20.0, 1e-9),
        closeTo(30.0, 1e-9),
      ]);
    });

    testWidgets('a row lays out on a narrow phone without overflowing', (
      tester,
    ) async {
      // The unit suffix widened the depth box, and the colour dropdown shows a
      // translated "default ink" phrase, so the row has to be able to give.
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await pumpSheet(tester, initial: twoLevels);
      expect(tester.takeException(), isNull);
    });

    testWidgets('each row is labelled with the diver depth unit', (
      tester,
    ) async {
      await pumpSheet(tester, initial: twoLevels);
      expect(levelFieldSuffix(tester, 0), 'm');
      await pumpSheet(
        tester,
        initial: twoLevels.copyWith(depthUnit: DepthUnit.feet),
      );
      expect(levelFieldSuffix(tester, 0), 'ft');
    });
  });

  testWidgets('the sheet keeps its content clear of the keyboard', (
    tester,
  ) async {
    // Issue #1094: without a viewInsets pad the lower rows and the add
    // button sit behind the keypad with no scroll extent to reach them.
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    addTearDown(tester.view.reset);
    await pumpSheetRoute(tester, initial: twoLevels);
    final padding = tester.widget<Padding>(
      find.byKey(const ValueKey('terrainAppearanceSheetInsets')),
    );
    expect(padding.padding.resolve(TextDirection.ltr).bottom, 280);
  });

  testWidgets('with the keypad open a long level list still scrolls fully', (
    tester,
  ) async {
    // The reporter's actual complaint: with many rows the bottom of the sheet
    // could not be brought into view while the keypad was up.
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    addTearDown(tester.view.reset);
    await pumpSheetRoute(tester, initial: manyLevels);

    // Every TextField nests its own Scrollable, so take the outermost.
    final position = tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byType(SingleChildScrollView),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position;
    expect(position.maxScrollExtent, greaterThan(0));
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();

    // Scrolled to the end, the last control clears the keypad rather than
    // sitting underneath it.
    expect(
      tester
          .getRect(find.byKey(const ValueKey('seascapeWallAngleSlider')))
          .bottom,
      lessThanOrEqualTo(800 - 320),
    );
  });
}
