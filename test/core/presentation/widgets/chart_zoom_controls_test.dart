import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/presentation/widgets/chart_zoom_controls.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

/// Mirrors the real hosts: the legend and the trend chart both pin the
/// controls to the trailing edge, so any width change moves the buttons.
Widget host(Widget child) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: SizedBox(
      width: 400,
      child: Align(alignment: AlignmentDirectional.centerEnd, child: child),
    ),
  ),
);

Widget controls(double zoomLevel, {double minZoom = 1}) => ChartZoomControls(
  keyPrefix: 'test',
  zoomLevel: zoomLevel,
  minZoom: minZoom,
  maxZoom: 8,
  onZoomIn: () {},
  onZoomOut: () {},
  onResetZoom: () {},
);

Finder byName(String name) => find.byKey(ValueKey('test-$name'));

void main() {
  testWidgets('the reset button renders only once zoomed', (tester) async {
    await tester.pumpWidget(host(controls(1)));
    expect(byName('zoom-reset'), findsNothing);

    await tester.pumpWidget(host(controls(2)));
    expect(byName('zoom-reset'), findsOneWidget);
  });

  testWidgets('the configured minimum is the unzoomed baseline', (
    tester,
  ) async {
    await tester.pumpWidget(host(controls(2, minZoom: 2)));
    expect(byName('zoom-reset'), findsNothing);

    await tester.pumpWidget(host(controls(3, minZoom: 2)));
    expect(byName('zoom-reset'), findsOneWidget);
  });

  testWidgets('zoom in stays put when the reset button appears', (
    tester,
  ) async {
    await tester.pumpWidget(host(controls(1)));
    final before = tester.getCenter(byName('zoom-in'));

    await tester.pumpWidget(host(controls(2)));
    final after = tester.getCenter(byName('zoom-in'));

    // The regression displaced the button by a whole 32px slot, so a
    // sub-pixel tolerance still catches it without tripping on layout
    // rounding.
    expect(after, offsetMoreOrLessEquals(before, epsilon: 0.5));
  });

  testWidgets('zoom out stays put when the reset button appears', (
    tester,
  ) async {
    await tester.pumpWidget(host(controls(1)));
    final before = tester.getCenter(byName('zoom-out'));

    await tester.pumpWidget(host(controls(2)));
    final after = tester.getCenter(byName('zoom-out'));

    expect(after, offsetMoreOrLessEquals(before, epsilon: 0.5));
  });

  testWidgets('the reset button leads the zoom controls', (tester) async {
    await tester.pumpWidget(host(controls(2)));

    expect(
      tester.getCenter(byName('zoom-reset')).dx,
      lessThan(tester.getCenter(byName('zoom-out')).dx),
    );
  });
}
