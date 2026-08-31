import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:submersion/core/utils/bounded_inflate.dart';

Uint8List _gzipped(List<int> body) => Uint8List.fromList(gzip.encode(body));

Uint8List _zlibbed(List<int> body) => Uint8List.fromList(zlib.encode(body));

void main() {
  group('inflateBounded', () {
    test('returns the body when it fits both caps', () {
      final body = utf8.encode('a track point or two');
      expect(
        inflateBounded(
          _gzipped(body),
          codec: gzip,
          maxBytes: 4096,
          maxBlobBytes: 4096,
        ),
        body,
      );
    });

    test('reads a zlib stream when handed the zlib codec', () {
      final body = utf8.encode('packed series body');
      expect(
        inflateBounded(
          _zlibbed(body),
          codec: zlib,
          maxBytes: 4096,
          maxBlobBytes: 4096,
        ),
        body,
      );
    });

    test('accepts a body of exactly maxBytes', () {
      final body = List<int>.filled(1024, 7);
      final inflated = inflateBounded(
        _gzipped(body),
        codec: gzip,
        maxBytes: 1024,
        maxBlobBytes: 4096,
      );
      expect(inflated.length, 1024);
    });

    test('refuses a body one byte over maxBytes', () {
      final body = List<int>.filled(1025, 7);
      expect(
        () => inflateBounded(
          _gzipped(body),
          codec: gzip,
          maxBytes: 1024,
          maxBlobBytes: 4096,
        ),
        throwsA(isA<BoundedInflateException>()),
      );
    });

    test('abandons a compression bomb the blob cap would have allowed', () {
      // 8 MiB of zeros gzips to a few KB: the blob sails under any sane
      // blob cap, and only the body cap can stop it.
      final bomb = _gzipped(Uint8List(8 * 1024 * 1024));
      expect(bomb.length, lessThan(64 * 1024));
      expect(
        () => inflateBounded(
          bomb,
          codec: gzip,
          maxBytes: 64 * 1024,
          maxBlobBytes: 1024 * 1024,
        ),
        throwsA(isA<BoundedInflateException>()),
      );
    });

    test('refuses an oversized blob before inflating it', () {
      // Well-formed and tiny once inflated, so only the blob cap can reject
      // it. Padding after a complete stream is copied natively before the
      // first chunk is emitted, which is why this check cannot live in the
      // sink.
      final padded = Uint8List.fromList([
        ..._gzipped(utf8.encode('short')),
        ...List<int>.filled(4096, 0),
      ]);
      expect(
        () => inflateBounded(
          padded,
          codec: gzip,
          maxBytes: 1024 * 1024,
          maxBlobBytes: 1024,
        ),
        throwsA(isA<BoundedInflateException>()),
      );
    });

    test('reports malformed input as a BoundedInflateException', () {
      final garbage = Uint8List.fromList(List<int>.filled(64, 0xAB));
      expect(
        () => inflateBounded(
          garbage,
          codec: gzip,
          maxBytes: 4096,
          maxBlobBytes: 4096,
        ),
        throwsA(isA<BoundedInflateException>()),
      );
    });

    test('does not treat the codec argument as a format check', () {
      // Dart's gzip decoder sniffs the header, so it reads a zlib stream
      // too. Pinned because it is the opposite of what the parameter name
      // suggests: callers that need to know which format they were handed
      // must frame it themselves.
      expect(
        inflateBounded(
          _zlibbed(utf8.encode('zlib body')),
          codec: gzip,
          maxBytes: 4096,
          maxBlobBytes: 4096,
        ),
        utf8.encode('zlib body'),
      );
    });

    test('names itself in toString, which is what a log prints', () {
      // The repository logs the exception object, not its message, so this
      // string is the one a reader actually sees.
      expect(
        const BoundedInflateException('too big').toString(),
        'BoundedInflateException: too big',
      );
    });

    test('rejects a negative body cap as a programming error', () {
      expect(
        () => inflateBounded(
          _gzipped(const [1, 2, 3]),
          codec: gzip,
          maxBytes: -1,
          maxBlobBytes: 4096,
        ),
        throwsArgumentError,
      );
    });

    test('rejects a negative blob cap as a programming error', () {
      expect(
        () => inflateBounded(
          _gzipped(const [1, 2, 3]),
          codec: gzip,
          maxBytes: 4096,
          maxBlobBytes: -1,
        ),
        throwsArgumentError,
      );
    });
  });
}
