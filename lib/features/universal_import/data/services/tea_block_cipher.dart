import 'dart:typed_data';

/// The Tiny Encryption Algorithm (Wheeler and Needham, 1994): a 64-bit block
/// cipher with a 128-bit key and 32 rounds of adds, shifts and XORs.
///
/// MacDive encrypts `ZDIVE.ZSAMPLES` with TEA in ECB mode under a key fixed
/// in its application binary; see `MacDiveSamplesDecoder`. That is the only
/// reason this class exists. TEA is decades past its cryptographic prime and
/// nothing else in the app should reach for it, so it does exactly what that
/// format needs: whole-buffer ECB in both directions, plus the single-block
/// primitives for tests that want to build fixtures.
///
/// Words are little-endian on the wire, matching how MacDive reads the
/// buffer as `uint32_t` pairs on Apple hardware.
class TeaBlockCipher {
  /// Takes the four 32-bit words `k[0]..k[3]` of the TEA key schedule. Each
  /// must already fit in 32 bits; the rounds reduce every sum modulo 2^32,
  /// so an oversized word would be silently folded rather than rejected.
  const TeaBlockCipher(this.k0, this.k1, this.k2, this.k3)
    : assert(k0 >= 0 && k0 <= _mask, 'k0 must be a 32-bit word'),
      assert(k1 >= 0 && k1 <= _mask, 'k1 must be a 32-bit word'),
      assert(k2 >= 0 && k2 <= _mask, 'k2 must be a 32-bit word'),
      assert(k3 >= 0 && k3 <= _mask, 'k3 must be a 32-bit word');

  final int k0;
  final int k1;
  final int k2;
  final int k3;

  /// Bytes per block.
  static const int blockSize = 8;

  /// The golden-ratio constant every TEA round adds to `sum`.
  static const int _delta = 0x9E3779B9;
  static const int _rounds = 32;
  static const int _mask = 0xFFFFFFFF;

  /// Decrypts [data] block by block. Returns a new buffer; [data] is left
  /// untouched. Throws [ArgumentError] when the length is not a whole number
  /// of blocks, since ECB has no padding of its own.
  Uint8List decrypt(Uint8List data) => _apply(data, decryptBlock);

  /// Encrypts [data] block by block. Same contract as [decrypt].
  Uint8List encrypt(Uint8List data) => _apply(data, encryptBlock);

  Uint8List _apply(Uint8List data, (int, int) Function(int, int) block) {
    if (data.length % blockSize != 0) {
      throw ArgumentError.value(
        data.length,
        'data',
        'length must be a multiple of $blockSize bytes',
      );
    }
    final out = Uint8List(data.length);
    final src = ByteData.sublistView(data);
    final dst = ByteData.sublistView(out);
    for (var offset = 0; offset < data.length; offset += blockSize) {
      final (v0, v1) = block(
        src.getUint32(offset, Endian.little),
        src.getUint32(offset + 4, Endian.little),
      );
      dst.setUint32(offset, v0, Endian.little);
      dst.setUint32(offset + 4, v1, Endian.little);
    }
    return out;
  }

  /// Encrypts one block given as two 32-bit words.
  (int, int) encryptBlock(int v0, int v1) {
    var sum = 0;
    for (var round = 0; round < _rounds; round++) {
      sum = (sum + _delta) & _mask;
      v0 = (v0 + _mix(v1, sum, k0, k1)) & _mask;
      v1 = (v1 + _mix(v0, sum, k2, k3)) & _mask;
    }
    return (v0, v1);
  }

  /// Decrypts one block given as two 32-bit words.
  (int, int) decryptBlock(int v0, int v1) {
    var sum = (_delta * _rounds) & _mask;
    for (var round = 0; round < _rounds; round++) {
      v1 = (v1 - _mix(v0, sum, k2, k3)) & _mask;
      v0 = (v0 - _mix(v1, sum, k0, k1)) & _mask;
      sum = (sum - _delta) & _mask;
    }
    return (v0, v1);
  }

  /// The TEA round function: `((v << 4) + k0) ^ (v + sum) ^ ((v >> 5) + k1)`,
  /// every term reduced to 32 bits.
  static int _mix(int v, int sum, int k0, int k1) =>
      ((((v << 4) & _mask) + k0) & _mask) ^
      ((v + sum) & _mask) ^
      (((v >> 5) + k1) & _mask);
}
