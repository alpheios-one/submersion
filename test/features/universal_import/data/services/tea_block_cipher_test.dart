import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:submersion/features/universal_import/data/services/tea_block_cipher.dart';

void main() {
  group('TeaBlockCipher', () {
    test('matches the published TEA known-answer vector', () {
      // Wheeler and Needham's reference: an all-zero key on an all-zero
      // block yields 41ea3a0a 94baa940.
      const cipher = TeaBlockCipher(0, 0, 0, 0);
      expect(cipher.encryptBlock(0, 0), (0x41EA3A0A, 0x94BAA940));
      expect(cipher.decryptBlock(0x41EA3A0A, 0x94BAA940), (0, 0));
    });

    test('decryptBlock inverts encryptBlock under a non-trivial key', () {
      // Computed with an independent Python implementation that was itself
      // checked against real MacDive data, so this pins the key-word order.
      const cipher = TeaBlockCipher(0x86, 0x16, 0x80, 0x60);
      expect(cipher.encryptBlock(0x01234567, 0x89ABCDEF), (
        0x4B3761A6,
        0xCA4F7DA4,
      ));
      expect(cipher.decryptBlock(0x4B3761A6, 0xCA4F7DA4), (
        0x01234567,
        0x89ABCDEF,
      ));
    });

    test('encrypt and decrypt walk a buffer block by block in ECB', () {
      const cipher = TeaBlockCipher(1, 2, 3, 4);
      final plain = Uint8List.fromList(List.generate(24, (i) => i * 9 & 0xFF));
      final encrypted = cipher.encrypt(plain);
      expect(encrypted, hasLength(24));
      expect(encrypted, isNot(equals(plain)));
      // ECB: identical plaintext blocks encrypt identically.
      final repeated = Uint8List.fromList([
        ...plain.sublist(0, 8),
        ...plain.sublist(0, 8),
      ]);
      final twice = cipher.encrypt(repeated);
      expect(twice.sublist(0, 8), twice.sublist(8, 16));
      expect(cipher.decrypt(encrypted), plain);
      // The input buffer is not modified in place.
      expect(plain[3], 27);
    });

    test('a buffer that is not whole blocks is rejected', () {
      const cipher = TeaBlockCipher(1, 2, 3, 4);
      expect(() => cipher.decrypt(Uint8List(12)), throwsArgumentError);
      expect(() => cipher.encrypt(Uint8List(1)), throwsArgumentError);
      expect(cipher.decrypt(Uint8List(0)), isEmpty);
    });

    test(
      'an all-zero block under the MacDive key is the surface signature',
      () {
        // The earlier investigation catalogued 84b90aa09fbb1ecc as a
        // "body prefix" on 56% of dives without knowing why. It is the
        // ciphertext of time 0.0 and depth 0.0, the first record of any dive
        // that starts at the surface.
        const cipher = TeaBlockCipher(0x86, 0x16, 0x80, 0x60);
        expect(cipher.encrypt(Uint8List(8)), [
          0x84,
          0xB9,
          0x0A,
          0xA0,
          0x9F,
          0xBB,
          0x1E,
          0xCC,
        ]);
      },
    );
  });
}
