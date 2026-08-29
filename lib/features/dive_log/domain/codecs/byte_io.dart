import 'dart:typed_data';

import 'package:submersion/features/dive_log/domain/codecs/profile_series_codec_exception.dart';

/// Presence mode for a column block: every value is null, no payload.
const int kPresenceAbsent = 0;

/// Presence mode for a column block: every value is present, no bitmap.
const int kPresenceAll = 1;

/// Presence mode for a column block: a bitmap of `ceil(n / 8)` bytes
/// (LSB-first within each byte) precedes the present values.
const int kPresenceBitmap = 2;

/// Append-only little-endian byte sink for the series codecs.
class ByteWriter {
  // copy: true (the default) matters: writeFloat64 hands the builder a view
  // of a reused scratch buffer, and a non-copying builder would alias every
  // float written to the same eight bytes.
  final BytesBuilder _builder = BytesBuilder();
  final ByteData _scratch = ByteData(8);

  void writeByte(int value) {
    assert(value >= 0 && value <= 0xFF, 'not a byte: $value');
    _builder.addByte(value);
  }

  /// Unsigned LEB128 varint: seven bits per byte, high bit set on all but
  /// the last byte.
  void writeVarUint(int value) {
    assert(value >= 0, 'varuint cannot encode $value');
    var remaining = value;
    while (remaining >= 0x80) {
      _builder.addByte((remaining & 0x7F) | 0x80);
      remaining >>= 7;
    }
    _builder.addByte(remaining);
  }

  /// Zigzag-mapped signed varint, so small negatives stay small: 0, -1, 1,
  /// -2, 2 map to 0, 1, 2, 3, 4.
  void writeVarInt(int value) => writeVarUint((value << 1) ^ (value >> 63));

  /// IEEE-754 binary64, little-endian, bit-exact.
  void writeFloat64(double value) {
    _scratch.setFloat64(0, value, Endian.little);
    _builder.add(_scratch.buffer.asUint8List(0, 8));
  }

  void writeBytes(List<int> bytes) => _builder.add(bytes);

  /// Returns everything written and resets the writer.
  Uint8List takeBytes() => _builder.takeBytes();
}

/// Strict forward-only reader over a byte buffer. Every read that would run
/// past the end throws [ProfileSeriesCodecException].
class ByteReader {
  ByteReader(Uint8List bytes)
    : _bytes = bytes,
      _data = ByteData.sublistView(bytes);

  final Uint8List _bytes;
  final ByteData _data;
  int _offset = 0;

  int get offset => _offset;
  int get remaining => _bytes.length - _offset;
  bool get isAtEnd => _offset >= _bytes.length;

  int readByte() {
    _ensure(1);
    return _bytes[_offset++];
  }

  int readVarUint() {
    var result = 0;
    var shift = 0;
    while (true) {
      final byte = readByte();
      if (shift == 63 && (byte & 0x7F) != 0) {
        throw const ProfileSeriesCodecException('varint overflows 63 bits');
      }
      result |= (byte & 0x7F) << shift;
      if ((byte & 0x80) == 0) return result;
      shift += 7;
      if (shift > 63) {
        throw const ProfileSeriesCodecException('varint longer than 64 bits');
      }
    }
  }

  int readVarInt() {
    final zigzag = readVarUint();
    return (zigzag >>> 1) ^ -(zigzag & 1);
  }

  double readFloat64() {
    _ensure(8);
    final value = _data.getFloat64(_offset, Endian.little);
    _offset += 8;
    return value;
  }

  Uint8List readBytes(int count) {
    _ensure(count);
    final view = Uint8List.sublistView(_bytes, _offset, _offset + count);
    _offset += count;
    return view;
  }

  void _ensure(int count) {
    if (count < 0 || _offset + count > _bytes.length) {
      throw ProfileSeriesCodecException(
        'unexpected end of data: needed $count byte(s) at offset $_offset '
        'of ${_bytes.length}',
      );
    }
  }
}

/// Column blocks: a presence mode byte, an optional bitmap, then only the
/// present values in order.
extension ColumnWriter on ByteWriter {
  /// Writes the presence mode and, when needed, the bitmap. Returns whether
  /// any value is present, so the caller knows whether to write payload.
  bool writePresence(List<Object?> values) {
    var presentCount = 0;
    for (final value in values) {
      if (value != null) presentCount++;
    }
    if (presentCount == 0) {
      writeByte(kPresenceAbsent);
      return false;
    }
    if (presentCount == values.length) {
      writeByte(kPresenceAll);
      return true;
    }
    writeByte(kPresenceBitmap);
    final bitmap = Uint8List((values.length + 7) >> 3);
    for (var i = 0; i < values.length; i++) {
      if (values[i] != null) bitmap[i >> 3] |= 1 << (i & 7);
    }
    writeBytes(bitmap);
    return true;
  }

  /// Writes one column: presence, then [writeValue] for each present value
  /// in order. [writeValue] may keep state between calls (delta encoding).
  void writeColumn<T extends Object>(
    List<T?> values,
    void Function(T value) writeValue,
  ) {
    if (!writePresence(values)) return;
    for (final value in values) {
      if (value != null) writeValue(value);
    }
  }
}

extension ColumnReader on ByteReader {
  /// Reads a presence block for [count] values.
  List<bool> readPresence(int count) {
    final mode = readByte();
    switch (mode) {
      case kPresenceAbsent:
        return List<bool>.filled(count, false);
      case kPresenceAll:
        return List<bool>.filled(count, true);
      case kPresenceBitmap:
        final bitmap = readBytes((count + 7) >> 3);
        return [
          for (var i = 0; i < count; i++)
            ((bitmap[i >> 3] >> (i & 7)) & 1) == 1,
        ];
      default:
        throw ProfileSeriesCodecException('unknown presence mode $mode');
    }
  }

  /// Reads one column of [count] values, calling [readValue] once per
  /// present value in order. [readValue] may keep state between calls.
  List<T?> readColumn<T extends Object>(int count, T Function() readValue) {
    final present = readPresence(count);
    return [for (final isPresent in present) isPresent ? readValue() : null];
  }
}
