import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/features/dive_log/domain/codecs/byte_io.dart';
import 'package:submersion/features/dive_log/domain/codecs/profile_series_codec_exception.dart';

/// The raw IEEE-754 bits, so -0.0 and NaN payloads compare exactly.
int bitsOf(double value) => (ByteData(
  8,
)..setFloat64(0, value, Endian.little)).getInt64(0, Endian.little);

void main() {
  group('varuint', () {
    for (final value in [
      0,
      1,
      127,
      128,
      255,
      300,
      16383,
      16384,
      1 << 31,
      (1 << 62) - 1,
    ]) {
      test('round-trips $value', () {
        final writer = ByteWriter()..writeVarUint(value);
        expect(ByteReader(writer.takeBytes()).readVarUint(), value);
      });
    }

    test('127 fits in one byte and 128 needs two', () {
      expect((ByteWriter()..writeVarUint(127)).takeBytes(), hasLength(1));
      expect((ByteWriter()..writeVarUint(128)).takeBytes(), hasLength(2));
    });
  });

  group('varint (zigzag)', () {
    for (final value in [
      0,
      -1,
      1,
      -2,
      2,
      -64,
      63,
      -65,
      64,
      -1000000,
      1000000,
      -(1 << 40),
      1 << 40,
    ]) {
      test('round-trips $value', () {
        final writer = ByteWriter()..writeVarInt(value);
        expect(ByteReader(writer.takeBytes()).readVarInt(), value);
      });
    }

    test('small negatives stay one byte', () {
      expect((ByteWriter()..writeVarInt(-1)).takeBytes(), hasLength(1));
      expect((ByteWriter()..writeVarInt(-64)).takeBytes(), hasLength(1));
      expect((ByteWriter()..writeVarInt(-65)).takeBytes(), hasLength(2));
    });
  });

  group('float64', () {
    for (final value in [
      0.0,
      -0.0,
      1.5,
      18.3,
      -273.15,
      double.maxFinite,
      double.minPositive,
      double.infinity,
      double.negativeInfinity,
    ]) {
      test('round-trips $value bit-exactly', () {
        final writer = ByteWriter()..writeFloat64(value);
        final bytes = writer.takeBytes();
        expect(bytes, hasLength(8));
        expect(bitsOf(ByteReader(bytes).readFloat64()), bitsOf(value));
      });
    }

    test('NaN round-trips as NaN', () {
      final writer = ByteWriter()..writeFloat64(double.nan);
      expect(ByteReader(writer.takeBytes()).readFloat64().isNaN, isTrue);
    });

    test('two consecutive floats do not alias each other', () {
      final writer = ByteWriter()
        ..writeFloat64(1.0)
        ..writeFloat64(2.0);
      final reader = ByteReader(writer.takeBytes());
      expect(reader.readFloat64(), 1.0);
      expect(reader.readFloat64(), 2.0);
    });
  });

  group('reader bounds', () {
    test('reading past the end throws', () {
      final reader = ByteReader(Uint8List.fromList([0x01]));
      reader.readByte();
      expect(reader.isAtEnd, isTrue);
      expect(reader.readByte, throwsA(isA<ProfileSeriesCodecException>()));
    });

    test('a float needs eight bytes', () {
      final reader = ByteReader(Uint8List.fromList([0, 0, 0, 0]));
      expect(reader.readFloat64, throwsA(isA<ProfileSeriesCodecException>()));
    });

    test('an unterminated varint throws', () {
      final reader = ByteReader(Uint8List.fromList([0x80, 0x80]));
      expect(reader.readVarUint, throwsA(isA<ProfileSeriesCodecException>()));
    });

    test('eleven continuation bytes throw', () {
      final reader = ByteReader(Uint8List.fromList(List.filled(11, 0x80)));
      expect(reader.readVarUint, throwsA(isA<ProfileSeriesCodecException>()));
    });

    test('a ten-byte varint whose payload reaches bit 63 throws', () {
      // Nine continuation bytes, then a terminating byte carrying bit 63.
      final reader = ByteReader(
        Uint8List.fromList([...List.filled(9, 0x80), 0x01]),
      );
      expect(reader.readVarUint, throwsA(isA<ProfileSeriesCodecException>()));
    });

    test('the largest 63-bit varint still decodes', () {
      // 2^63 - 1: eight bytes of 0xFF then 0x7F.
      final reader = ByteReader(
        Uint8List.fromList([...List.filled(8, 0xFF), 0x7F]),
      );
      expect(reader.readVarUint(), (1 << 63) - 1);
    });

    test('readBytes past the end throws', () {
      final reader = ByteReader(Uint8List.fromList([1, 2, 3]));
      expect(
        () => reader.readBytes(4),
        throwsA(isA<ProfileSeriesCodecException>()),
      );
    });

    test('offset and remaining track consumption', () {
      final reader = ByteReader(Uint8List.fromList([1, 2, 3]));
      reader.readByte();
      expect(reader.offset, 1);
      expect(reader.remaining, 2);
    });
  });

  group('columns', () {
    // Note: `writer` is declared on its own line in every case below. Dart
    // rejects a closure that names the variable being initialised
    // ("referenced before declaration"), so the cascade form cannot be used.

    test('an all-null column costs exactly one byte', () {
      final writer = ByteWriter();
      writer.writeColumn<int>([null, null, null], writer.writeVarInt);
      final bytes = writer.takeBytes();
      expect(bytes, [kPresenceAbsent]);
      final reader = ByteReader(bytes);
      expect(reader.readColumn<int>(3, reader.readVarInt), [null, null, null]);
      expect(reader.isAtEnd, isTrue);
    });

    test('a fully present column carries no bitmap', () {
      final writer = ByteWriter();
      writer.writeColumn<int>([5, 6, 7], writer.writeVarInt);
      final bytes = writer.takeBytes();
      expect(bytes.first, kPresenceAll);
      expect(bytes, hasLength(4));
      final reader = ByteReader(bytes);
      expect(reader.readColumn<int>(3, reader.readVarInt), [5, 6, 7]);
    });

    test('a mixed column uses a bitmap and round-trips across a byte edge', () {
      // Nine values force a two-byte bitmap.
      final values = <int?>[1, null, 3, null, null, 6, 7, null, 9];
      final writer = ByteWriter();
      writer.writeColumn<int>(values, writer.writeVarInt);
      final bytes = writer.takeBytes();
      expect(bytes.first, kPresenceBitmap);
      // mode + 2 bitmap bytes + 5 one-byte values
      expect(bytes, hasLength(8));
      final reader = ByteReader(bytes);
      expect(reader.readColumn<int>(9, reader.readVarInt), values);
      expect(reader.isAtEnd, isTrue);
    });

    test('float columns round-trip through the same presence logic', () {
      final values = <double?>[1.5, null, -2.25];
      final writer = ByteWriter();
      writer.writeColumn<double>(values, writer.writeFloat64);
      final reader = ByteReader(writer.takeBytes());
      expect(reader.readColumn<double>(3, reader.readFloat64), values);
    });

    test('an unknown presence mode throws', () {
      final reader = ByteReader(Uint8List.fromList([7]));
      expect(
        () => reader.readColumn<int>(1, reader.readVarInt),
        throwsA(isA<ProfileSeriesCodecException>()),
      );
    });

    test('an empty column writes only the absent marker', () {
      final writer = ByteWriter();
      writer.writeColumn<int>(const [], writer.writeVarInt);
      expect(writer.takeBytes(), [kPresenceAbsent]);
    });
  });
}
