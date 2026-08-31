/// Thrown when a packed series blob cannot be decoded.
///
/// Decoders never guess. An unknown version byte, a truncated payload,
/// trailing bytes, or a block that disagrees with its field table all end
/// here rather than in a partial sample list.
class ProfileSeriesCodecException implements Exception {
  const ProfileSeriesCodecException(this.message);

  final String message;

  @override
  String toString() => 'ProfileSeriesCodecException: $message';
}
