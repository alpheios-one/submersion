import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'package:submersion/features/media/data/services/exif_date_parser.dart';
import 'package:submersion/features/media/data/services/isobmff_boxes.dart';

/// Reads the capture time from a media file's own container metadata using
/// pure-Dart parsers (no native plugins), for the platforms and files where
/// `native_exif` yields nothing (macOS/Windows/Linux, or any file it cannot
/// date). Returns a wall-clock-UTC [DateTime] — the same frame
/// `DivePhotoMatcher` compares dive times in — or null when no reliable capture
/// time is present, leaving the caller to fall back to the file mtime.
///
/// - JPEG: EXIF `DateTimeOriginal` (via `package:image`, EXIF-only, no pixel
///   decode).
/// - HEIC/HEIF: EXIF from the ISO-BMFF `meta` box's `Exif` item (iPhone's
///   default photo format; `package:image` cannot decode HEIC pixels, but the
///   embedded EXIF is a standard TIFF block once located).
/// - MP4/MOV/M4V: the `moov > mvhd` `creation_time` from the ISO-BMFF/QuickTime
///   container.
DateTime? readLocalCaptureTime(File file, String mime) {
  switch (mime) {
    case 'image/jpeg':
      return _readJpegExifDate(file);
    case 'image/heic':
    case 'image/heif':
      return _readHeicExifDate(file);
    case 'video/mp4':
    case 'video/quicktime':
    case 'video/x-m4v':
      return _readMp4CreationTime(file);
    default:
      return null;
  }
}

DateTime? _readJpegExifDate(File file) {
  try {
    final exif = img.decodeJpgExif(file.readAsBytesSync());
    if (exif == null) return null;
    return _dateFromExif(exif);
  } on Object {
    // Truncated/corrupt JPEG or an unreadable file: fall back to mtime.
    return null;
  }
}

/// Pulls a wall-clock-UTC date from a parsed [img.ExifData]. EXIF date tags are
/// ASCII "YYYY:MM:DD HH:MM:SS"; prefer the shutter time (DateTimeOriginal),
/// then when it was digitized, then the basic file DateTime.
DateTime? _dateFromExif(img.ExifData exif) {
  final raw =
      exif.exifIfd['DateTimeOriginal'] ??
      exif.exifIfd['DateTimeDigitized'] ??
      exif.imageIfd['DateTime'];
  return parseExifDateTimeOriginal(raw?.toString());
}

// Upper bounds on HEIC reads. Real `meta` boxes and `Exif` items are tens of KB
// (the meta box carries no pixel data); these caps only exist to reject a
// corrupt/crafted length before it triggers a large allocation.
const _maxMetaBytes = 64 * 1024 * 1024;
const _maxExifItemBytes = 64 * 1024 * 1024;

/// Reads EXIF from a HEIC/HEIF file. HEIC is ISO-BMFF: the EXIF lives in a
/// metadata item declared by the `meta > iinf` box (type `Exif`) and located
/// by `meta > iloc`. We read only the `meta` box and the Exif item's extent
/// (not the multi-MB image data), then hand the embedded TIFF block to
/// `package:image`'s EXIF parser.
DateTime? _readHeicExifDate(File file) {
  RandomAccessFile? raf;
  try {
    raf = file.openSync();
    final end = raf.lengthSync();
    final meta = findBox(raf, 0, end, 'meta');
    if (meta == null) return null;
    // `meta` is a FullBox: its child boxes start 4 (version+flags) bytes in.
    // Bound the read: reject a too-small box (nothing to parse / underflow) or
    // an absurdly large one (a crafted meta could be huge yet within EOF) so we
    // fall back to mtime rather than risk a large allocation. The meta box holds
    // only metadata, never pixel data, so it is small in practice.
    final metaLen = meta.end - meta.start - 4;
    if (metaLen <= 0 || metaLen > _maxMetaBytes) return null;
    raf.setPositionSync(meta.start + 4);
    final metaBytes = raf.readSync(metaLen);

    final iinf = findBoxInBytes(metaBytes, 0, metaBytes.length, 'iinf');
    final iloc = findBoxInBytes(metaBytes, 0, metaBytes.length, 'iloc');
    if (iinf == null || iloc == null) return null;

    final itemId = _heicExifItemId(metaBytes, iinf.start, iinf.end);
    if (itemId == null) return null;
    final extent = _heicExifExtent(metaBytes, iloc.start, iloc.end, itemId);
    if (extent == null) return null;
    // Reject a corrupt/crafted extent that points past EOF or advertises an
    // absurd length, so we fall back to mtime instead of attempting a huge
    // read/allocation. Real EXIF items are a few KB.
    if (extent.offset < 0 ||
        extent.length <= 0 ||
        extent.length > _maxExifItemBytes ||
        extent.offset + extent.length > end) {
      return null;
    }

    raf.setPositionSync(extent.offset);
    final item = raf.readSync(extent.length);
    final tiff = _tiffHeaderOffset(item);
    if (tiff == null) return null;

    final exif = img.ExifData.fromInputBuffer(
      img.InputBuffer(item.sublist(tiff)),
    );
    return _dateFromExif(exif);
  } on Object {
    return null;
  } finally {
    raf?.closeSync();
  }
}

/// Finds the `Exif` item's id in an `iinf` box's content range. Each `infe`
/// entry carries the item id (uint16 in v<3, uint32 in v3+) followed by the
/// protection index and a four-char item type.
int? _heicExifItemId(Uint8List b, int start, int end) {
  final version = b[start];
  var p = start + 4; // skip version + flags
  final int count;
  if (version == 0) {
    count = beU16(b, p);
    p += 2;
  } else {
    count = beU32(b, p);
    p += 4;
  }
  for (var i = 0; i < count && p + 8 <= end; i++) {
    final size = beU32(b, p);
    if (size < 8 || p + size > end) return null;
    final infeEnd = p + size;
    final infeVersion = b[p + 8];
    final idBytes = infeVersion >= 3 ? 4 : 2; // item_ID width
    final itemId = infeVersion >= 3 ? beU32(b, p + 12) : beU16(b, p + 12);
    // item_type follows: infe header (8) + version/flags (4) + item_ID +
    // item_protection_index (2). Bound the read to THIS infe box so a corrupt
    // size can't match an 'Exif' fourCC that belongs to a following entry.
    final typePos = p + 12 + idBytes + 2;
    if (typePos + 4 <= infeEnd && fourCC(b, typePos) == 'Exif') return itemId;
    p += size;
  }
  return null;
}

/// Resolves the byte extent (absolute offset + length) of item [wantId] from an
/// `iloc` box's content range.
_Extent? _heicExifExtent(Uint8List b, int start, int end, int wantId) {
  final version = b[start];
  var p = start + 4; // skip version + flags
  final offsetSize = b[p] >> 4;
  final lengthSize = b[p] & 0xf;
  final baseOffsetSize = b[p + 1] >> 4;
  final indexSize = b[p + 1] & 0xf;
  p += 2;
  final int itemCount;
  if (version < 2) {
    itemCount = beU16(b, p);
    p += 2;
  } else {
    itemCount = beU32(b, p);
    p += 4;
  }

  int readSized(int n) {
    var v = 0;
    for (var i = 0; i < n; i++) {
      v = (v << 8) | b[p + i];
    }
    p += n;
    return v;
  }

  for (var i = 0; i < itemCount && p < end; i++) {
    final id = version < 2 ? beU16(b, p) : beU32(b, p);
    p += version < 2 ? 2 : 4;
    if (version == 1 || version == 2) p += 2; // construction_method
    p += 2; // data_reference_index
    final baseOffset = readSized(baseOffsetSize);
    final extentCount = beU16(b, p);
    p += 2;
    for (var e = 0; e < extentCount; e++) {
      if ((version == 1 || version == 2) && indexSize > 0) readSized(indexSize);
      final off = readSized(offsetSize);
      final len = readSized(lengthSize);
      if (id == wantId) return _Extent(baseOffset + off, len);
    }
  }
  return null;
}

/// The HEIC `Exif` item begins with a 4-byte big-endian offset to the TIFF
/// header (counted from just past that field). Use it directly; fall back to a
/// bounded scan only when the declared offset is out of range or does not point
/// at a TIFF signature, so malformed input degrades gracefully instead of
/// mis-locating an earlier byte sequence.
int? _tiffHeaderOffset(Uint8List b) {
  if (b.length >= 8) {
    final declared = 4 + beU32(b, 0);
    if (declared + 4 <= b.length && _isTiffHeader(b, declared)) return declared;
  }
  for (var i = 0; i + 4 <= b.length; i++) {
    if (_isTiffHeader(b, i)) return i;
  }
  return null;
}

/// A TIFF header is `II*\0` (little-endian) or `MM\0*` (big-endian).
bool _isTiffHeader(Uint8List b, int o) =>
    (b[o] == 0x49 &&
        b[o + 1] == 0x49 &&
        b[o + 2] == 0x2a &&
        b[o + 3] == 0x00) ||
    (b[o] == 0x4d && b[o + 1] == 0x4d && b[o + 2] == 0x00 && b[o + 3] == 0x2a);

class _Extent {
  const _Extent(this.offset, this.length);
  final int offset;
  final int length;
}

// Seconds between the QuickTime/ISO-BMFF epoch (1904-01-01) and the Unix epoch.
// This is a whole number of days, so the epoch shift preserves the time-of-day
// digits exactly (only the date rolls) when reconstructing the DateTime.
const _secondsBetween1904And1970 = 2082844800;

DateTime? _readMp4CreationTime(File file) {
  RandomAccessFile? raf;
  try {
    raf = file.openSync();
    final end = raf.lengthSync();
    // The movie header (mvhd) lives inside moov. Cameras such as GoPro place
    // moov AFTER the multi-hundred-MB mdat, so we walk top-level boxes by size,
    // seeking past mdat without ever reading its bytes.
    final moov = findBox(raf, 0, end, 'moov');
    if (moov == null) return null;
    final mvhd = findBox(raf, moov.start, moov.end, 'mvhd');
    if (mvhd == null) return null;

    final version = readByteAt(raf, mvhd.start);
    // Only v0/v1 mvhd headers exist. Bail on anything else rather than
    // mis-reading a corrupt byte as v0 and emitting a bogus timestamp.
    if (version != 0 && version != 1) return null;
    // creation_time follows the 1-byte version + 3 flag bytes. It is uint32 in
    // a v0 header and uint64 in a v1 header.
    final creation = version == 1
        ? readU64At(raf, mvhd.start + 4)
        : readU32At(raf, mvhd.start + 4);
    if (creation == 0) return null; // 0 == "unknown"; caller uses mtime.

    // GoPro (and most cameras) write the LOCAL wall clock into creation_time.
    // Reconstructing it as a UTC DateTime preserves those digits as
    // wall-clock-UTC, matching how EXIF and mtime are handled here.
    return DateTime.fromMillisecondsSinceEpoch(
      (creation - _secondsBetween1904And1970) * 1000,
      isUtc: true,
    );
  } on Object {
    return null;
  } finally {
    raf?.closeSync();
  }
}
