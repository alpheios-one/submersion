import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/gas_calculators/presentation/pages/blender_settings_page.dart';
import 'package:submersion/features/gas_calculators/presentation/providers/gas_blender_providers.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

import '../../support/fake_app_settings_repository.dart';

class _TestSettingsNotifier extends StateNotifier<AppSettings>
    implements SettingsNotifier {
  _TestSettingsNotifier(super.settings);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// The Riverpod `Override` type is sealed and not re-exported, so overrides
// are threaded through as `dynamic` and cast at the `ProviderScope` boundary
// (see test/helpers/test_app.dart).
Future<WidgetRef> _pump(
  WidgetTester tester, {
  List<dynamic> overrides = const [],
}) async {
  late WidgetRef captured;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsProvider.overrideWith(
          (ref) => _TestSettingsNotifier(const AppSettings()),
        ),
        ...overrides,
      ].cast(),
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Consumer(
          builder: (context, ref, _) {
            captured = ref;
            return const BlenderSettingsPage();
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return captured;
}

void main() {
  testWidgets('submitting a fill-gas row saves the preferences', (
    tester,
  ) async {
    // Issue #1335: fill gases now persist across restarts too, the same as
    // the cylinder and target fill.
    final repo = FakeAppSettingsRepository();
    final ref = await _pump(
      tester,
      overrides: [appSettingsRepositoryProvider.overrideWithValue(repo)],
    );

    // The first fill-gas row's O2 field: no pressure column on this card, so
    // O2 is the very first field.
    await tester.enterText(find.byType(TextField).first, '95');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(ref.read(blenderFillGas1Provider).o2, closeTo(95, 0.001));
    expect(repo.blenderPreferences?.fillGas1.o2, closeTo(95, 0.001));
  });
}
