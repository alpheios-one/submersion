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

Widget controls(double zoomLevel) => ChartZoomControls(
  keyPrefix: 'test',
  zoomLevel: zoomLevel,
  minZoom: 1,
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

  testWidgets('zoom in stays put when the reset button appears', (
    tester,
  ) async {
    await tester.pumpWidget(host(controls(1)));
    final before = tester.getCenter(byName('zoom-in'));

    await tester.pumpWidget(host(controls(2)));
    final after = tester.getCenter(byName('zoom-in'));

    expect(after, before);
  });

  testWidgets('zoom out stays put when the reset button appears', (
    tester,
  ) async {
    await tester.pumpWidget(host(controls(1)));
    final before = tester.getCenter(byName('zoom-out'));

    await tester.pumpWidget(host(controls(2)));
    final after = tester.getCenter(byName('zoom-out'));

    expect(after, before);
  });

  testWidgets('the reset button leads the zoom controls', (tester) async {
    await tester.pumpWidget(host(controls(2)));

    expect(
      tester.getCenter(byName('zoom-reset')).dx,
      lessThan(tester.getCenter(byName('zoom-out')).dx),
    );
  });
}
