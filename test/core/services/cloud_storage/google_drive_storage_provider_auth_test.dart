import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:submersion/core/services/cloud_storage/cloud_storage_provider.dart';
import 'package:submersion/core/services/cloud_storage/google_drive/google_drive_authenticator.dart';
import 'package:submersion/core/services/cloud_storage/google_drive/google_drive_client_config.dart';
import 'package:submersion/core/services/cloud_storage/google_drive_storage_provider.dart';

/// Exercises the provider through the [GoogleDriveAuthenticator] seam: auth
/// delegation, the 401 retry, and error mapping. The transfer paths that take
/// a file path are covered separately in
/// google_drive_storage_provider_test.dart, which injects a DriveApi directly.
class _FakeAuthenticator implements GoogleDriveAuthenticator {
  _FakeAuthenticator(this._client);

  http.Client? _client;
  int authenticateCalls = 0;
  int silentAuthCalls = 0;
  int authFailures = 0;
  int allowSilentAuthCalls = 0;
  bool silentAuthResult = true;
  bool signedOut = false;

  @override
  http.Client? get authClient => _client;

  @override
  Future<void> authenticate() async => authenticateCalls++;

  @override
  Future<bool> attemptSilentAuth() async {
    silentAuthCalls++;
    return silentAuthResult;
  }

  @override
  Future<void> allowSilentAuth() async => allowSilentAuthCalls++;

  @override
  Future<void> handleAuthFailure() async => authFailures++;

  @override
  Future<void> signOut() async {
    signedOut = true;
    _client = null;
  }

  @override
  Future<String?> get userEmail async => 'diver@example.com';
}

const _jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

/// Minimal fake Drive v3 backend. List responses are keyed by a substring
/// of the q query parameter (folder lookups contain the folder mimeType,
/// file lookups contain the file name).
class _FakeDrive {
  final List<http.Request> requests = [];
  final Map<String, List<Map<String, Object?>>> listResponses = {};
  int failuresRemaining = 0;
  int failureStatus = 401;
  String failureReason = 'authError';

  MockClient client() => MockClient((request) async {
    requests.add(request);
    if (failuresRemaining > 0) {
      failuresRemaining--;
      return http.Response(
        jsonEncode({
          'error': {
            'code': failureStatus,
            'message': 'fake failure',
            'errors': [
              {'reason': failureReason, 'message': 'fake failure'},
            ],
          },
        }),
        failureStatus,
        headers: _jsonHeaders,
      );
    }
    final path = request.url.path;
    if (request.method == 'GET' && path == '/drive/v3/files') {
      final q = request.url.queryParameters['q'] ?? '';
      for (final entry in listResponses.entries) {
        if (q.contains(entry.key)) {
          return http.Response(
            jsonEncode({'files': entry.value}),
            200,
            headers: _jsonHeaders,
          );
        }
      }
      return http.Response(
        jsonEncode({'files': <Object?>[]}),
        200,
        headers: _jsonHeaders,
      );
    }
    if (request.method == 'POST' && path == '/upload/drive/v3/files') {
      return http.Response(
        jsonEncode({'id': 'created-1', 'name': 'created'}),
        200,
        headers: _jsonHeaders,
      );
    }
    if ((request.method == 'PATCH' || request.method == 'PUT') &&
        path.startsWith('/upload/drive/v3/files/')) {
      return http.Response(
        jsonEncode({'id': path.split('/').last, 'name': 'updated'}),
        200,
        headers: _jsonHeaders,
      );
    }
    if (request.method == 'POST' && path == '/drive/v3/files') {
      return http.Response(
        jsonEncode({'id': 'folder-created-1', 'name': 'Submersion Sync'}),
        200,
        headers: _jsonHeaders,
      );
    }
    if (request.method == 'GET' && path.startsWith('/drive/v3/files/')) {
      if (request.url.queryParameters['alt'] == 'media') {
        return http.Response.bytes(
          [1, 2, 3],
          200,
          headers: {'content-type': 'application/octet-stream'},
        );
      }
      return http.Response(
        jsonEncode({
          'id': path.split('/').last,
          'name': 'meta.json',
          'modifiedTime': '2026-07-02T10:00:00.000Z',
          'size': '3',
        }),
        200,
        headers: _jsonHeaders,
      );
    }
    if (request.method == 'DELETE') {
      return http.Response('', 204);
    }
    return http.Response('unexpected ${request.method} $path', 500);
  });
}

const _folderQueryKey = "mimeType = 'application/vnd.google-apps.folder'";

void main() {
  late _FakeDrive drive_;
  late _FakeAuthenticator auth;
  late GoogleDriveStorageProvider provider;

  setUp(() {
    drive_ = _FakeDrive();
    drive_.listResponses[_folderQueryKey] = [
      {'id': 'folder-7', 'name': 'Submersion Sync'},
    ];
    auth = _FakeAuthenticator(drive_.client());
    provider = GoogleDriveStorageProvider(authenticator: auth);
  });

  test('isAvailable is platform + desktop-config gated', () async {
    final expected = (Platform.isWindows || Platform.isLinux)
        ? GoogleDriveClientConfig.hasDesktopClient
        : true;
    expect(await provider.isAvailable(), expected);
  });

  test('isAuthenticated delegates to silent auth when no client yet', () async {
    final unauthenticated = GoogleDriveStorageProvider(
      authenticator: _FakeAuthenticator(null)..silentAuthResult = false,
    );
    expect(await unauthenticated.isAuthenticated(), isFalse);
  });

  test('getUserEmail delegates to the authenticator', () async {
    expect(await provider.getUserEmail(), 'diver@example.com');
  });

  test(
    'mediaHttpClient lifts the silent-auth gate and yields the client',
    () async {
      final client = await provider.mediaHttpClient();
      expect(auth.allowSilentAuthCalls, 1);
      expect(client, isNotNull);
    },
  );

  test('mediaHttpClient returns null when no session can be built', () async {
    final fake = _FakeAuthenticator(null)..silentAuthResult = false;
    final offline = GoogleDriveStorageProvider(authenticator: fake);
    expect(await offline.mediaHttpClient(), isNull);
    expect(fake.allowSilentAuthCalls, 1);
  });

  test('an injected DriveApi outranks the authenticator client', () async {
    // The transfer tests construct a provider with no usable authenticator;
    // injection has to win or every call would throw "Not authenticated".
    final injected = GoogleDriveStorageProvider(
      authenticator: _FakeAuthenticator(null)..silentAuthResult = false,
    )..debugSetDriveApi(drive.DriveApi(drive_.client()));

    expect(await injected.getFileInfo('file-1'), isNotNull);
  });

  test('upload creates a new file when none exists by that name', () async {
    final result = await provider.uploadFile(
      Uint8List.fromList([1, 2]),
      'ssv1.dev.cs.000001.json',
    );
    expect(result.fileId, 'created-1');
    expect(
      drive_.requests.any(
        (r) => r.method == 'POST' && r.url.path == '/upload/drive/v3/files',
      ),
      isTrue,
    );
  });

  test('upload updates in place when the name already exists', () async {
    drive_.listResponses["name = 'ssv1.dev.manifest.json'"] = [
      {'id': 'existing-9', 'name': 'ssv1.dev.manifest.json'},
    ];
    final result = await provider.uploadFile(
      Uint8List.fromList([1, 2]),
      'ssv1.dev.manifest.json',
    );
    expect(result.fileId, 'existing-9');
    expect(
      drive_.requests.any(
        (r) => r.url.path == '/upload/drive/v3/files/existing-9',
      ),
      isTrue,
    );
  });

  test('the sync folder id is cached across calls', () async {
    await provider.uploadFile(Uint8List.fromList([1]), 'a.json');
    await provider.uploadFile(Uint8List.fromList([2]), 'b.json');
    final folderQueries = drive_.requests.where(
      (r) => (r.url.queryParameters['q'] ?? '').contains(_folderQueryKey),
    );
    expect(folderQueries, hasLength(1));
  });

  test('download returns the file bytes', () async {
    final bytes = await provider.downloadFile('file-1');
    expect(bytes, Uint8List.fromList([1, 2, 3]));
  });

  test('listFiles maps Drive results to CloudFileInfo', () async {
    drive_.listResponses['ssv1.'] = [
      {
        'id': 'f1',
        'name': 'ssv1.dev.cs.000001.json',
        'modifiedTime': '2026-07-01T00:00:00.000Z',
        'size': '10',
      },
    ];
    final files = await provider.listFiles(namePattern: 'ssv1.');
    expect(files, hasLength(1));
    expect(files.single.id, 'f1');
    expect(files.single.sizeBytes, 10);
  });

  test('deleteFile issues a DELETE', () async {
    await provider.deleteFile('f1');
    expect(drive_.requests.last.method, 'DELETE');
    expect(drive_.requests.last.url.path, '/drive/v3/files/f1');
  });

  test('a 401 triggers one silent re-auth and a retry', () async {
    drive_.failuresRemaining = 1;
    final files = await provider.listFiles(namePattern: 'ssv1.');
    expect(files, isEmpty);
    expect(auth.authFailures, 1);
    expect(auth.silentAuthCalls, 1);
  });

  test('a 401 with failed re-auth surfaces a sign-in-again error', () async {
    drive_.failuresRemaining = 1;
    auth.silentAuthResult = false;
    await expectLater(
      provider.listFiles(namePattern: 'ssv1.'),
      throwsA(
        isA<CloudStorageException>().having(
          (e) => e.message,
          'message',
          contains('sign in'),
        ),
      ),
    );
  });

  test('quota exhaustion maps to a storage-is-full error', () async {
    drive_.failuresRemaining = 1;
    drive_.failureStatus = 403;
    drive_.failureReason = 'storageQuotaExceeded';
    await expectLater(
      provider.listFiles(namePattern: 'ssv1.'),
      throwsA(
        isA<CloudStorageException>().having(
          (e) => e.message,
          'message',
          contains('storage is full'),
        ),
      ),
    );
  });

  test('signOut resets provider caches and delegates', () async {
    await provider.uploadFile(Uint8List.fromList([1]), 'a.json');
    await provider.signOut();
    expect(auth.signedOut, isTrue);
    expect(await provider.getFileInfo('x'), isNull);
  });
}
