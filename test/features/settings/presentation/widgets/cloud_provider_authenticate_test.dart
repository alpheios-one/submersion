import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/data/repositories/sync_repository.dart'
    show CloudProviderType;
import 'package:submersion/core/services/cloud_storage/cloud_storage_provider.dart';
import 'package:submersion/features/settings/presentation/widgets/cloud_provider_authenticate.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

/// Authenticates only when the test completes [authCompleter], standing in for
/// the desktop loopback round trip through the system browser.
class _PendingAuthProvider implements CloudStorageProvider {
  final authCompleter = Completer<void>();

  @override
  Future<void> authenticate() => authCompleter.future;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  /// Hosts a button that runs the helper, so the "page underneath" is a real
  /// route whose survival can be asserted.
  Future<void> pumpHost(
    WidgetTester tester,
    CloudStorageProvider provider, {
    required void Function(Object error) onError,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  try {
                    await authenticateWithBrowserWait(
                      context,
                      provider,
                      CloudProviderType.googledrive,
                      // The platform branch is Windows/Linux only; force it so
                      // this runs on every host rather than being skipped on
                      // the machines most developers use.
                      debugForceBrowserWait: true,
                    );
                  } catch (e) {
                    onError(e);
                  }
                },
                child: const Text('connect'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('the wait dialog cannot be dismissed by a route pop', (
    tester,
  ) async {
    // Regression: with the dialog poppable, an Escape or back gesture left
    // dialogClosed false, so the pending auth's completion handler fired a
    // second Navigator.pop that took the page route underneath with it.
    final provider = _PendingAuthProvider();
    await pumpHost(tester, provider, onError: (_) {});

    await tester.tap(find.text('connect'));
    await tester.pump();
    expect(find.byType(AlertDialog), findsOneWidget);

    // A route-level pop request (Escape, system back) must not take it down.
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    await navigator.maybePop();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);

    // Auth settling closes the dialog and leaves the host page standing.
    provider.authCompleter.complete();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('connect'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a pop that bypasses PopScope cannot pop the page underneath', (
    tester,
  ) async {
    // Belt-and-braces half of the same fix: even an imperative pop, which
    // PopScope does not gate, must not leave the late auth completion free to
    // pop a second route.
    final provider = _PendingAuthProvider();
    await pumpHost(tester, provider, onError: (_) {});

    await tester.tap(find.text('connect'));
    await tester.pump();
    expect(find.byType(AlertDialog), findsOneWidget);

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);

    provider.authCompleter.complete();
    await tester.pumpAndSettle();

    // The host page survived: nothing popped it on the way out.
    expect(find.text('connect'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Cancel abandons the flow and swallows its late error', (
    tester,
  ) async {
    final provider = _PendingAuthProvider();
    Object? error;
    await pumpHost(tester, provider, onError: (e) => error = e);

    await tester.tap(find.text('connect'));
    await tester.pump();

    final cancelLabel = MaterialLocalizations.of(
      tester.element(find.byType(AlertDialog)),
    ).cancelButtonLabel;
    await tester.tap(find.text(cancelLabel));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(error, isA<CloudStorageException>());
    expect(find.text('connect'), findsOneWidget);

    // The abandoned loopback listener eventually times out; its error must
    // not surface after the user has already cancelled.
    provider.authCompleter.completeError(
      const CloudStorageException('loopback timeout'),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('no dialog on platforms that authenticate directly', (
    tester,
  ) async {
    final provider = _PendingAuthProvider();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => authenticateWithBrowserWait(
                  context,
                  provider,
                  CloudProviderType.googledrive,
                  debugForceBrowserWait: false,
                ),
                child: const Text('connect'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('connect'));
    await tester.pump();
    expect(find.byType(AlertDialog), findsNothing);

    provider.authCompleter.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
