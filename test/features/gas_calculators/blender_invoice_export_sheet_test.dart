import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:share_plus_platform_interface/share_plus_platform_interface.dart';

import 'package:submersion/core/services/export/export_service.dart';
import 'package:submersion/features/gas_calculators/presentation/widgets/blender/blender_invoice_export_sheet.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

/// The share helpers write into getApplicationDocumentsDirectory(), a
/// platform channel with no implementation under flutter_test.
class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.documentsPath);
  final String documentsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => documentsPath;
}

class _FakeSharePlatform extends SharePlatform {
  final List<ShareParams> calls = [];

  @override
  Future<ShareResult> share(ShareParams params) async {
    calls.add(params);
    return const ShareResult('ok', ShareResultStatus.success);
  }
}

void main() {
  late Directory documents;
  final platform = _FakeSharePlatform();

  setUpAll(() => SharePlatform.instance = platform);

  setUp(() {
    documents = Directory.systemTemp.createTempSync(
      'blender_invoice_export_test',
    );
    PathProviderPlatform.instance = _FakePathProvider(documents.path);
    platform.calls.clear();
  });

  tearDown(() => documents.deleteSync(recursive: true));

  const data = BlenderInvoiceExportData(
    date: 'Invoice dated Mar 5, 2026',
    billedTo: 'Ada',
    tariff: 'O2 CHF 1.20/100L',
    fills: [
      BlenderInvoiceExportFill(
        label: 'Tx 18/45',
        total: 'CHF 35.00',
        lines: [
          BlenderInvoiceExportLine(
            gas: 'O2',
            volume: '30 L',
            cost: 'CHF 10.00',
          ),
        ],
      ),
    ],
    total: 'CHF 35.00',
    incomplete: false,
  );

  Future<void> pump(WidgetTester tester) async {
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: RepaintBoundary(
            key: boundaryKey,
            child: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    builder: (context) => BlenderInvoiceExportSheet(
                      data: data,
                      imageBoundaryKey: boundaryKey,
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('offers PDF, image and Excel as the three export options', (
    tester,
  ) async {
    await pump(tester);

    expect(find.byKey(const Key('blender-export-pdf')), findsOneWidget);
    expect(find.byKey(const Key('blender-export-image')), findsOneWidget);
    expect(find.byKey(const Key('blender-export-excel')), findsOneWidget);
  });

  testWidgets('tapping PDF shares a PDF and closes the sheet', (tester) async {
    await pump(tester);

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('blender-export-pdf')));
      await _settleWithLoadingIndicator(tester);
    });
    await tester.pumpAndSettle();

    expect(platform.calls, hasLength(1));
    expect(platform.calls.single.files!.single.mimeType, 'application/pdf');
    expect(find.byType(BlenderInvoiceExportSheet), findsNothing);
  });

  testWidgets('tapping Excel shares a spreadsheet and closes the sheet', (
    tester,
  ) async {
    await pump(tester);

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('blender-export-excel')));
      await _settleWithLoadingIndicator(tester);
    });
    await tester.pumpAndSettle();

    expect(platform.calls, hasLength(1));
    expect(
      platform.calls.single.files!.single.mimeType,
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    );
    expect(find.byType(BlenderInvoiceExportSheet), findsNothing);
  });

  testWidgets('tapping Image captures the boundary and shares a PNG', (
    tester,
  ) async {
    await pump(tester);

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('blender-export-image')));
      await _settleWithLoadingIndicator(tester);
    });

    expect(platform.calls, hasLength(1));
    expect(platform.calls.single.files!.single.mimeType, 'image/png');
  });
}

/// A bounded pump loop rather than [WidgetTester.pumpAndSettle]: the export
/// tile shows a [CircularProgressIndicator] while its future is in flight,
/// and that ticks forever, so `pumpAndSettle` never sees "no more frames
/// scheduled" and times out even once the real work underneath is done. Runs
/// inside [WidgetTester.runAsync] (see the call sites) so the real file I/O
/// and PDF/Excel encoding behind the export actually get to complete -
/// plain `pump()` only flushes work already done, it does not wait for it.
Future<void> _settleWithLoadingIndicator(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump();
  }
}
