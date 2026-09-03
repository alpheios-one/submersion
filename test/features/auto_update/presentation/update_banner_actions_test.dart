import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/features/auto_update/domain/entities/linux_install_method.dart';
import 'package:submersion/features/auto_update/presentation/widgets/update_banner_actions.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

Widget _host(LinuxInstallMethod method, {String? downloadUrl}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  locale: const Locale('en'),
  home: Scaffold(
    body: UpdateBannerActions(
      installMethod: method,
      downloadUrl: downloadUrl,
      onDownload: (_) {},
      onDismiss: () {},
    ),
  ),
);

void main() {
  const url = 'https://example.invalid/Submersion-Linux.tar.gz';

  testWidgets('tarball install offers a download button', (tester) async {
    await tester.pumpWidget(
      _host(LinuxInstallMethod.tarball, downloadUrl: url),
    );
    expect(find.text('Download'), findsOneWidget);
  });

  testWidgets('deb install shows the apt command, not a download', (
    tester,
  ) async {
    await tester.pumpWidget(_host(LinuxInstallMethod.deb, downloadUrl: url));
    expect(find.text('Download'), findsNothing);
    expect(find.textContaining('sudo apt upgrade submersion'), findsOneWidget);
  });

  testWidgets('rpm install shows the dnf command', (tester) async {
    await tester.pumpWidget(_host(LinuxInstallMethod.rpm, downloadUrl: url));
    expect(find.text('Download'), findsNothing);
    expect(find.textContaining('sudo dnf upgrade submersion'), findsOneWidget);
  });

  testWidgets('a packaged install shows no download even with a url', (
    tester,
  ) async {
    await tester.pumpWidget(_host(LinuxInstallMethod.deb, downloadUrl: url));
    expect(find.byType(TextButton), findsNothing);
  });

  testWidgets('dismiss is always available', (tester) async {
    await tester.pumpWidget(_host(LinuxInstallMethod.deb));
    expect(find.byIcon(Icons.close), findsOneWidget);
  });

  testWidgets('a tarball install with no url offers no download button', (
    tester,
  ) async {
    await tester.pumpWidget(_host(LinuxInstallMethod.tarball));
    expect(find.text('Download'), findsNothing);
    expect(find.byIcon(Icons.close), findsOneWidget);
  });

  test('upgradeCommand is empty for a tarball install', () {
    expect(
      UpdateBannerActions.upgradeCommand(LinuxInstallMethod.tarball),
      isEmpty,
    );
  });
}
