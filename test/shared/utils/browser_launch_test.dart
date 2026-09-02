import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/shared/utils/browser_launch.dart';

void main() {
  final uri = Uri.parse('https://www.dropbox.com/oauth2/authorize?x=1');

  group('openInBrowser off Linux', () {
    test(
      'returns true and never shells out when url_launcher succeeds',
      () async {
        final spawned = <List<String>>[];
        final opened = await openInBrowser(
          uri,
          onLinux: false,
          launch: (_) async => true,
          spawn: (exe, args) async {
            spawned.add([exe, ...args]);
            return true;
          },
        );
        expect(opened, isTrue);
        expect(spawned, isEmpty);
      },
    );

    test(
      'returns false without a fallback chain when url_launcher declines',
      () async {
        final spawned = <List<String>>[];
        final opened = await openInBrowser(
          uri,
          onLinux: false,
          launch: (_) async => false,
          spawn: (exe, args) async {
            spawned.add([exe, ...args]);
            return true;
          },
        );
        expect(opened, isFalse);
        // The generic openers are Linux-only: macOS and Windows have their own
        // working url_launcher implementations, and spawning xdg-open there
        // would only produce a confusing "command not found".
        expect(spawned, isEmpty);
      },
    );

    test(
      'rethrows a launch failure so callers keep the platform message',
      () async {
        expect(
          () => openInBrowser(
            uri,
            onLinux: false,
            launch: (_) async => throw PlatformException(code: 'Launch Error'),
            spawn: (_, _) async => true,
          ),
          throwsA(isA<PlatformException>()),
        );
      },
    );
  });

  group('openInBrowser on Linux', () {
    test(
      'does not shell out when url_launcher already opened a browser',
      () async {
        final spawned = <List<String>>[];
        final opened = await openInBrowser(
          uri,
          onLinux: true,
          launch: (_) async => true,
          spawn: (exe, args) async {
            spawned.add([exe, ...args]);
            return true;
          },
        );
        expect(opened, isTrue);
        expect(spawned, isEmpty);
      },
    );

    test('falls back to xdg-open when url_launcher returns false', () async {
      final spawned = <List<String>>[];
      final opened = await openInBrowser(
        uri,
        onLinux: true,
        launch: (_) async => false,
        spawn: (exe, args) async {
          spawned.add([exe, ...args]);
          return true;
        },
      );
      expect(opened, isTrue);
      expect(spawned, [
        ['xdg-open', uri.toString()],
      ]);
    });

    test('falls back rather than rethrowing when url_launcher throws, which is '
        'how url_launcher_linux reports "no https scheme handler"', () async {
      final spawned = <List<String>>[];
      final opened = await openInBrowser(
        uri,
        onLinux: true,
        launch: (_) async =>
            throw PlatformException(code: 'Launch Error', message: 'no app'),
        spawn: (exe, args) async {
          spawned.add([exe, ...args]);
          return true;
        },
      );
      expect(opened, isTrue);
      expect(spawned.single.first, 'xdg-open');
    });

    test('walks the whole opener chain in order and gives up', () async {
      final spawned = <List<String>>[];
      final opened = await openInBrowser(
        uri,
        onLinux: true,
        launch: (_) async => false,
        spawn: (exe, args) async {
          spawned.add([exe, ...args]);
          return false;
        },
      );
      expect(opened, isFalse);
      expect(spawned, [
        ['xdg-open', uri.toString()],
        // gio needs its open subcommand ahead of the URL.
        ['gio', 'open', uri.toString()],
        // Debian's alternatives system resolves these even when GIO has no
        // registered scheme handler, which is the Debian 13 failure this
        // chain exists for.
        ['x-www-browser', uri.toString()],
        ['sensible-browser', uri.toString()],
      ]);
    });

    test('skips an opener that is not installed and keeps going', () async {
      final spawned = <List<String>>[];
      final opened = await openInBrowser(
        uri,
        onLinux: true,
        launch: (_) async => false,
        spawn: (exe, args) async {
          spawned.add([exe, ...args]);
          // Process.start throws rather than returning non-zero when the
          // executable is absent, which is routine on a minimal desktop.
          if (exe != 'x-www-browser') {
            throw const ProcessException('missing', <String>[]);
          }
          return true;
        },
      );
      expect(opened, isTrue);
      expect(spawned.map((c) => c.first), ['xdg-open', 'gio', 'x-www-browser']);
    });

    test('stops at the first opener that takes the URL', () async {
      final spawned = <List<String>>[];
      await openInBrowser(
        uri,
        onLinux: true,
        launch: (_) async => false,
        spawn: (exe, args) async {
          spawned.add([exe, ...args]);
          return exe == 'gio';
        },
      );
      expect(spawned.map((c) => c.first), ['xdg-open', 'gio']);
    });
  });

  // Real processes, not doubles: this is the one part of the fallback that
  // has to behave correctly against a live OS, and the unit suite runs on a
  // Linux runner, which is the platform the chain exists for. Every command
  // here is POSIX and present on both the CI image and a dev Mac.
  group('spawnBrowserOpener', () {
    const settle = Duration(milliseconds: 100);

    test('reports success when the opener hands off and exits 0', () async {
      // The xdg-open / gio open shape: prints, exits immediately.
      expect(
        await spawnBrowserOpener('/bin/echo', ['ok'], settleWindow: settle),
        isTrue,
      );
    });

    test('reports failure when the opener exits non-zero', () async {
      // What xdg-open does when it cannot resolve a handler, and the signal
      // that must send openInBrowser on to the next entry in the chain.
      expect(
        await spawnBrowserOpener('/bin/sh', [
          '-c',
          'exit 3',
        ], settleWindow: settle),
        isFalse,
      );
    });

    test('treats a process still running after the settle window as a '
        'success, because x-www-browser IS the browser', () async {
      // Waiting for this one to exit would mean waiting for the user to
      // quit their browser, then launching a second one.
      expect(
        await spawnBrowserOpener('/bin/sh', [
          '-c',
          'sleep 1',
        ], settleWindow: settle),
        isTrue,
      );
    });

    test('throws ProcessException for an executable that is not installed', () {
      // Not a false return: openInBrowser catches this shape separately,
      // since a missing opener is routine rather than a failed launch.
      expect(
        () => spawnBrowserOpener('submersion-no-such-opener', const [
          'https://example.com',
        ], settleWindow: settle),
        throwsA(isA<ProcessException>()),
      );
    });

    test(
      'drains stdout so a chatty opener cannot block on a full pipe',
      () async {
        // A browser started as our child writes to the inherited pipe; without
        // the drain it wedges at the 64KB buffer and never opens anything.
        expect(
          await spawnBrowserOpener('/bin/sh', [
            '-c',
            'yes submersion | head -c 200000',
          ], settleWindow: const Duration(seconds: 5)),
          isTrue,
        );
      },
    );
  });

  test('linuxBrowserOpeners documents the chain the fallback walks', () {
    expect(linuxBrowserOpeners, [
      ['xdg-open'],
      ['gio', 'open'],
      ['x-www-browser'],
      ['sensible-browser'],
    ]);
  });
}
