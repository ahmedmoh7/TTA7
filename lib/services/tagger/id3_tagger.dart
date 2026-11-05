import 'dart:convert';
import 'dart:typed_data';

/// Prepends standard ID3v2.3 metadata (title, artist, album, lyrics, cover art)
/// to MP3 audio files.
class Id3Tagger {
  /// Tag MP3 bytes with metadata.
  /// Returns the tagged bytes, or original bytes if tagging fails.
  static Uint8List tag(
    Uint8List bytes, {
    String? title,
    String? artist,
    String? album,
    String? lyrics,
    Uint8List? coverBytes,
    bool coverIsPng = false,
  }) {
    try {
      final frames = <Uint8List>[];

      if (title != null && title.trim().isNotEmpty) {
        frames.add(_textFrame('TIT2', title.trim()));
      }
      if (artist != null && artist.trim().isNotEmpty) {
        frames.add(_textFrame('TPE1', artist.trim()));
      }
      if (album != null && album.trim().isNotEmpty) {
        frames.add(_textFrame('TALB', album.trim()));
      }
      if (lyrics != null && lyrics.trim().isNotEmpty) {
        frames.add(_lyricsFrame(lyrics.trim()));
      }
      if (coverBytes != null && coverBytes.isNotEmpty) {
        frames.add(_pictureFrame(coverBytes, coverIsPng));
      }

      if (frames.isEmpty) return bytes;

      // Calculate total frames length
      final framesPayloadLen = frames.fold<int>(
        0,
        (sum, frame) => sum + frame.length,
      );

      // Build 10-byte ID3v2.3 header
      final header = Uint8List(10);
      header[0] = 0x49; // 'I'
      header[1] = 0x44; // 'D'
      header[2] = 0x33; // '3'
      header[3] = 0x03; // Version 2.3
      header[4] = 0x00; // Revision
      header[5] = 0x00; // Flags

      // Synchsafe integer for frame size (4 bytes, 7 bits each)
      header[6] = (framesPayloadLen >> 21) & 0x7F;
      header[7] = (framesPayloadLen >> 14) & 0x7F;
      header[8] = (framesPayloadLen >> 7) & 0x7F;
      header[9] = framesPayloadLen & 0x7F;

      // Check if file already has an ID3v2 tag to skip
      var audioStart = 0;
      if (bytes.length >= 10 &&
          bytes[0] == 0x49 &&
          bytes[1] == 0x44 &&
          bytes[2] == 0x33) {
        final existingSize = ((bytes[6] & 0x7F) << 21) |
            ((bytes[7] & 0x7F) << 14) |
            ((bytes[8] & 0x7F) << 7) |
            (bytes[9] & 0x7F);
        final tagLen = 10 + existingSize;
        if (tagLen <= bytes.length) {
          audioStart = tagLen;
        }
      }

      final audioData = bytes.sublist(audioStart);
      final result = Uint8List(
        header.length + framesPayloadLen + audioData.length,
      );

      result.setRange(0, header.length, header);
      var p = header.length;
      for (final frame in frames) {
        result.setRange(p, p + frame.length, frame);
        p += frame.length;
      }
      result.setRange(p, result.length, audioData);

      return result;
    } catch (_) {
      return bytes;
    }
  }

  /// Create text frame (e.g. TIT2, TPE1, TALB)
  static Uint8List _textFrame(String frameId, String text) {
    final textBytes = utf8.encode(text);
    // 1 byte encoding (0x03 = UTF-8) + text bytes
    final payload = Uint8List(1 + textBytes.length);
    payload[0] = 0x03;
    payload.setRange(1, payload.length, textBytes);

    return _buildFrame(frameId, payload);
  }

  /// Create USLT (Unsynchronized lyrics) frame
  static Uint8List _lyricsFrame(String lyrics) {
    final textBytes = utf8.encode(lyrics);
    // 1 byte encoding (0x03 = UTF-8) + 3 bytes lang ('eng') + 1 byte desc (0x00) + text
    final payload = Uint8List(1 + 3 + 1 + textBytes.length);
    payload[0] = 0x03;
    payload[1] = 0x65; // 'e'
    payload[2] = 0x6E; // 'n'
    payload[3] = 0x67; // 'g'
    payload[4] = 0x00; // Empty description delimiter
    payload.setRange(5, payload.length, textBytes);

    return _buildFrame('USLT', payload);
  }

  /// Create APIC (Attached picture) frame
  static Uint8List _pictureFrame(Uint8List imageBytes, bool isPng) {
    final mime = isPng ? 'image/png' : 'image/jpeg';
    final mimeBytes = latin1.encode(mime);

    // 1 byte encoding (0x00 = ISO-8859-1) + mimeBytes + 0x00 + 1 byte picType (0x03) + 0x00 desc + imageBytes
    final payload = Uint8List(1 + mimeBytes.length + 1 + 1 + 1 + imageBytes.length);
    payload[0] = 0x00;
    payload.setRange(1, 1 + mimeBytes.length, mimeBytes);
    payload[1 + mimeBytes.length] = 0x00;
    payload[1 + mimeBytes.length + 1] = 0x03; // 0x03 = Front Cover
    payload[1 + mimeBytes.length + 2] = 0x00; // Empty description delimiter
    payload.setRange(1 + mimeBytes.length + 3, payload.length, imageBytes);

    return _buildFrame('APIC', payload);
  }

  /// Wraps payload in 10-byte ID3v2.3 frame header
  static Uint8List _buildFrame(String frameId, Uint8List payload) {
    final frame = Uint8List(10 + payload.length);
    final idBytes = latin1.encode(frameId);
    frame.setRange(0, 4, idBytes);

    // 32-bit big-endian size
    final len = payload.length;
    frame[4] = (len >> 24) & 0xFF;
    frame[5] = (len >> 16) & 0xFF;
    frame[6] = (len >> 8) & 0xFF;
    frame[7] = len & 0xFF;

    frame[8] = 0x00; // Flags
    frame[9] = 0x00;

    frame.setRange(10, frame.length, payload);
    return frame;
  }
}
