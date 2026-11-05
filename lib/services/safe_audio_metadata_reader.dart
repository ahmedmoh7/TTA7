import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Extracted metadata from a local audio file
class SafeAudioMetadata {
  final String? title;
  final String? artist;
  final String? album;
  final Duration? duration;
  final int? trackNumber;
  final Uint8List? pictureBytes;
  final String? pictureMime;

  const SafeAudioMetadata({
    this.title,
    this.artist,
    this.album,
    this.duration,
    this.trackNumber,
    this.pictureBytes,
    this.pictureMime,
  });

  bool get hasBasicMetadata =>
      (title != null && title!.trim().isNotEmpty) ||
      (artist != null && artist!.trim().isNotEmpty);
}

/// Robust, leak-proof audio metadata reader.
///
/// Guarantees:
/// 1. All file handles are closed via try...finally (zero file descriptor leaks).
/// 2. Handles FLAC files with or without prepended ID3v2 headers.
/// 3. Vorbis comment parser handles missing '=', multiple '=', and malformed UTF-8 without throwing.
/// 4. Skips PICTURE and PADDING blocks during scanning so memory is never blown up.
/// 5. No byte-by-byte full-file scanning (prevents ANR and watchdog timeouts).
class SafeAudioMetadataReader {
  /// Read metadata from a file safely without leaking file handles or blowing memory.
  static SafeAudioMetadata readMetadata(
    File file, {
    bool extractPicture = false,
  }) {
    final path = file.path.toLowerCase();

    // 1. Specialized FLAC parser
    if (path.endsWith('.flac')) {
      final meta = _readFlacMetadata(file, extractPicture: extractPicture);
      if (meta != null) return meta;
    }

    // 2. Specialized MP4 / M4A parser
    if (path.endsWith('.m4a') || path.endsWith('.mp4') || path.endsWith('.aac')) {
      final meta = _readMp4Metadata(file, extractPicture: extractPicture);
      if (meta != null) return meta;
    }

    // 3. Specialized MP3 / ID3v2 parser
    if (path.endsWith('.mp3')) {
      final meta = _readId3Metadata(file, extractPicture: extractPicture);
      if (meta != null) return meta;
    }

    // 4. Header-based format detection fallback (e.g. extension might not match)
    final detectedMeta = _detectAndReadByHeader(file, extractPicture: extractPicture);
    if (detectedMeta != null) return detectedMeta;

    // 5. Filename-based fallback
    return parseFilenameFallback(file.path);
  }

  /// Parse title and artist from filename as a safe, 0-cost fallback.
  static SafeAudioMetadata parseFilenameFallback(String filePath) {
    final normalized = filePath.replaceAll('\\', '/');
    final fileName = normalized.split('/').last;
    final nameWithoutExt = fileName.replaceAll(RegExp(r'\.[^.]+$'), '');

    String title = '';
    String artist = '';

    if (nameWithoutExt.contains(' - ')) {
      final parts = nameWithoutExt.split(' - ');
      artist = parts[0].trim();
      title = parts.sublist(1).join(' - ').trim();
    } else {
      title = nameWithoutExt.trim();
      artist = 'Unknown Artist';
    }

    if (title.isEmpty) title = 'Unknown Track';
    if (artist.isEmpty) artist = 'Unknown Artist';

    return SafeAudioMetadata(
      title: title,
      artist: artist,
      album: null,
      duration: const Duration(minutes: 3),
    );
  }

  // ===========================================================================
  // FLAC Parser
  // ===========================================================================

  static SafeAudioMetadata? _readFlacMetadata(
    File file, {
    required bool extractPicture,
  }) {
    RandomAccessFile? raf;
    try {
      if (!file.existsSync()) return null;
      raf = file.openSync(mode: FileMode.read);
      final fileLength = raf.lengthSync();
      if (fileLength < 4) return null;

      int currentPos = 0;
      raf.setPositionSync(0);

      // Check for ID3v2 tag prepended to FLAC
      final initialHeader = raf.readSync(4);
      if (initialHeader.length == 4 &&
          initialHeader[0] == 0x49 && // 'I'
          initialHeader[1] == 0x44 && // 'D'
          initialHeader[2] == 0x33) { // '3'
        // Read remaining 6 bytes of ID3v2 header
        final id3Rest = raf.readSync(6);
        if (id3Rest.length == 6) {
          final tagSize = _readSyncSafeInt(id3Rest, 2);
          currentPos = 10 + tagSize;
          if (currentPos + 4 <= fileLength) {
            raf.setPositionSync(currentPos);
          }
        }
      } else {
        raf.setPositionSync(0);
        currentPos = 0;
      }

      // Verify 'fLaC' marker
      final flacMarker = raf.readSync(4);
      if (flacMarker.length < 4 ||
          flacMarker[0] != 0x66 || // 'f'
          flacMarker[1] != 0x4C || // 'L'
          flacMarker[2] != 0x61 || // 'a'
          flacMarker[3] != 0x43) { // 'C'
        return null;
      }
      currentPos += 4;

      Duration? duration;
      String? title;
      String? artist;
      String? album;
      int? trackNumber;
      Uint8List? pictureBytes;
      String? pictureMime;

      bool isLastBlock = false;
      int blockCount = 0;

      // Read metadata blocks
      while (!isLastBlock && currentPos < fileLength && blockCount < 100) {
        blockCount++;
        raf.setPositionSync(currentPos);
        final headerBytes = raf.readSync(4);
        if (headerBytes.length < 4) break;

        final byte0 = headerBytes[0];
        isLastBlock = (byte0 & 0x80) != 0;
        final blockType = byte0 & 0x7F;
        final blockLength =
            (headerBytes[1] << 16) | (headerBytes[2] << 8) | headerBytes[3];

        currentPos += 4;

        if (blockLength < 0 || currentPos + blockLength > fileLength) {
          break; // Corrupted block length
        }

        switch (blockType) {
          case 0: // STREAMINFO (34 bytes)
            if (blockLength >= 34) {
              final streamInfo = raf.readSync(34);
              if (streamInfo.length >= 34) {
                // Bytes 10-17 contain sample rate (20 bits), channels (3 bits),
                // bits per sample (5 bits), total samples (36 bits)
                final byteData = ByteData.sublistView(streamInfo, 10, 18);
                final infoInt64 = byteData.getUint64(0);

                final sampleRate = (infoInt64 >> 44) & 0xFFFFF;
                final totalSamples = infoInt64 & 0xFFFFFFFFF;

                if (sampleRate > 0 && totalSamples > 0) {
                  final durationMs = (totalSamples * 1000) ~/ sampleRate;
                  duration = Duration(milliseconds: durationMs);
                }
              }
            }
            break;

          case 4: // VORBIS_COMMENT
            // Bound read length to reasonable size (max 2MB for tags)
            final readLen = min(blockLength, 2 * 1024 * 1024);
            final commentBytes = raf.readSync(readLen);
            final comments = _parseVorbisComments(commentBytes);

            title ??= comments['TITLE'];
            artist ??= comments['ARTIST'] ?? comments['ALBUMARTIST'];
            album ??= comments['ALBUM'];
            if (comments['TRACKNUMBER'] != null) {
              final tnStr = comments['TRACKNUMBER']!;
              final cleanTn = tnStr.split('/').first.trim();
              trackNumber ??= int.tryParse(cleanTn);
            }
            break;

          case 6: // PICTURE
            if (extractPicture && pictureBytes == null) {
              // Only load picture if explicitly requested (e.g. artwork service)
              final picLen = min(blockLength, 20 * 1024 * 1024); // max 20MB
              final picBlock = raf.readSync(picLen);
              final pic = _parseFlacPicture(picBlock);
              if (pic != null) {
                pictureBytes = pic.bytes;
                pictureMime = pic.mime;
              }
            }
            break;

          default:
            // Skip other blocks (PADDING, APPLICATION, SEEKTABLE, etc.) with zero memory allocation
            break;
        }

        currentPos += blockLength;

        // If not extracting picture and we have all essential metadata, we can finish early
        if (!extractPicture &&
            title != null &&
            artist != null &&
            album != null &&
            duration != null) {
          break;
        }
      }

      return SafeAudioMetadata(
        title: title,
        artist: artist,
        album: album,
        duration: duration,
        trackNumber: trackNumber,
        pictureBytes: pictureBytes,
        pictureMime: pictureMime,
      );
    } catch (_) {
      return null;
    } finally {
      try {
        raf?.closeSync();
      } catch (_) {}
    }
  }

  /// Parse Vorbis comment block safely without index out of bounds or UTF-8 crashes
  static Map<String, String> _parseVorbisComments(Uint8List bytes) {
    final result = <String, String>{};
    if (bytes.length < 8) return result;

    try {
      int offset = 0;

      // 1. Vendor string length (little-endian uint32)
      final vendorLen = _readUint32LE(bytes, offset);
      offset += 4;
      if (offset + vendorLen > bytes.length) return result;
      offset += vendorLen; // skip vendor string

      // 2. User comment list length (little-endian uint32)
      if (offset + 4 > bytes.length) return result;
      final commentListLen = _readUint32LE(bytes, offset);
      offset += 4;

      // Bound iterations to avoid infinite loop on corrupt data
      final maxComments = min(commentListLen, 500);

      for (int i = 0; i < maxComments; i++) {
        if (offset + 4 > bytes.length) break;
        final commentLen = _readUint32LE(bytes, offset);
        offset += 4;

        if (commentLen < 0 || offset + commentLen > bytes.length) break;

        final commentStr = utf8.decode(
          bytes.sublist(offset, offset + commentLen),
          allowMalformed: true,
        );
        offset += commentLen;

        final eqIndex = commentStr.indexOf('=');
        if (eqIndex != -1) {
          final key = commentStr.substring(0, eqIndex).trim().toUpperCase();
          final val = commentStr.substring(eqIndex + 1).trim();
          if (val.isNotEmpty && !result.containsKey(key)) {
            result[key] = val;
          }
        }
      }
    } catch (_) {}

    return result;
  }

  /// Parse FLAC PICTURE metadata block
  static ({Uint8List bytes, String mime})? _parseFlacPicture(Uint8List bytes) {
    if (bytes.length < 32) return null;
    try {
      int offset = 0;
      // Picture type (4 bytes BE)
      offset += 4;

      // MIME type length (4 bytes BE)
      final mimeLen = _readUint32BE(bytes, offset);
      offset += 4;
      if (offset + mimeLen > bytes.length) return null;

      final mime = utf8.decode(
        bytes.sublist(offset, offset + mimeLen),
        allowMalformed: true,
      );
      offset += mimeLen;

      // Description length (4 bytes BE)
      if (offset + 4 > bytes.length) return null;
      final descLen = _readUint32BE(bytes, offset);
      offset += 4;
      if (offset + descLen > bytes.length) return null;
      offset += descLen; // skip description

      // Width (4), Height (4), Color depth (4), Indexed colors (4) = 16 bytes
      offset += 16;
      if (offset + 4 > bytes.length) return null;

      // Picture data length (4 bytes BE)
      final dataLen = _readUint32BE(bytes, offset);
      offset += 4;
      if (offset + dataLen > bytes.length) return null;

      final picBytes = bytes.sublist(offset, offset + dataLen);
      return (bytes: picBytes, mime: mime.isNotEmpty ? mime : 'image/jpeg');
    } catch (_) {
      return null;
    }
  }

  // ===========================================================================
  // MP4 / M4A Parser
  // ===========================================================================

  static SafeAudioMetadata? _readMp4Metadata(
    File file, {
    required bool extractPicture,
  }) {
    RandomAccessFile? raf;
    try {
      if (!file.existsSync()) return null;
      raf = file.openSync(mode: FileMode.read);
      final fileLength = raf.lengthSync();
      if (fileLength < 16) return null;

      String? title;
      String? artist;
      String? album;
      Duration? duration;
      int? trackNumber;
      Uint8List? pictureBytes;
      String? pictureMime;

      int pos = 0;

      // Walk top-level atoms (ftyp, moov, etc.)
      while (pos + 8 <= fileLength) {
        raf.setPositionSync(pos);
        final atomHeader = raf.readSync(8);
        if (atomHeader.length < 8) break;

        final atomSize = _readUint32BE(atomHeader, 0);
        final atomName = String.fromCharCodes(atomHeader.sublist(4, 8));

        int actualSize = atomSize;
        int headerSize = 8;

        if (atomSize == 1) {
          // 64-bit size
          final extHeader = raf.readSync(8);
          if (extHeader.length < 8) break;
          actualSize = _readUint64BE(extHeader, 0);
          headerSize = 16;
        } else if (atomSize == 0) {
          actualSize = fileLength - pos;
        }

        if (actualSize < headerSize || pos + actualSize > fileLength) break;

        if (atomName == 'moov') {
          // Read moov payload (bound to max 10MB)
          final moovPayloadSize = min(actualSize - headerSize, 10 * 1024 * 1024);
          raf.setPositionSync(pos + headerSize);
          final moovBytes = raf.readSync(moovPayloadSize);

          // Parse mvhd for duration
          duration = _parseMp4Duration(moovBytes);

          // Parse ilst inside moov.udta.meta
          final ilstMeta = _parseMp4Ilst(moovBytes, extractPicture: extractPicture);
          title = ilstMeta.title;
          artist = ilstMeta.artist;
          album = ilstMeta.album;
          trackNumber = ilstMeta.trackNumber;
          if (extractPicture && ilstMeta.pictureBytes != null) {
            pictureBytes = ilstMeta.pictureBytes;
            pictureMime = ilstMeta.pictureMime;
          }
          break; // Found moov, done
        }

        pos += actualSize;
      }

      return SafeAudioMetadata(
        title: title,
        artist: artist,
        album: album,
        duration: duration,
        trackNumber: trackNumber,
        pictureBytes: pictureBytes,
        pictureMime: pictureMime,
      );
    } catch (_) {
      return null;
    } finally {
      try {
        raf?.closeSync();
      } catch (_) {}
    }
  }

  static Duration? _parseMp4Duration(Uint8List moovBytes) {
    try {
      int offset = 0;
      while (offset + 8 <= moovBytes.length) {
        final size = _readUint32BE(moovBytes, offset);
        if (size < 8 || offset + size > moovBytes.length) break;
        final name = String.fromCharCodes(moovBytes.sublist(offset + 4, offset + 8));

        if (name == 'mvhd') {
          final version = moovBytes[offset + 8];
          if (version == 1 && offset + 36 <= moovBytes.length) {
            final timescale = _readUint32BE(moovBytes, offset + 28);
            final dur = _readUint64BE(moovBytes, offset + 32);
            if (timescale > 0 && dur > 0) {
              return Duration(milliseconds: (dur * 1000) ~/ timescale);
            }
          } else if (version == 0 && offset + 28 <= moovBytes.length) {
            final timescale = _readUint32BE(moovBytes, offset + 20);
            final dur = _readUint32BE(moovBytes, offset + 24);
            if (timescale > 0 && dur > 0) {
              return Duration(milliseconds: (dur * 1000) ~/ timescale);
            }
          }
          break;
        }
        offset += size;
      }
    } catch (_) {}
    return null;
  }

  static ({
    String? title,
    String? artist,
    String? album,
    int? trackNumber,
    Uint8List? pictureBytes,
    String? pictureMime,
  }) _parseMp4Ilst(Uint8List moovBytes, {required bool extractPicture}) {
    String? title;
    String? artist;
    String? album;
    int? trackNumber;
    Uint8List? pictureBytes;
    String? pictureMime;

    try {
      // Find 'ilst' atom offset inside moovBytes
      final ilstTag = [0x69, 0x6C, 0x73, 0x74]; // 'ilst'
      int ilstOffset = -1;
      for (int i = 0; i < moovBytes.length - 8; i++) {
        if (moovBytes[i] == ilstTag[0] &&
            moovBytes[i + 1] == ilstTag[1] &&
            moovBytes[i + 2] == ilstTag[2] &&
            moovBytes[i + 3] == ilstTag[3]) {
          ilstOffset = i - 4; // atom size starts 4 bytes earlier
          break;
        }
      }

      if (ilstOffset < 0) {
        return (
          title: null,
          artist: null,
          album: null,
          trackNumber: null,
          pictureBytes: null,
          pictureMime: null,
        );
      }

      final ilstSize = _readUint32BE(moovBytes, ilstOffset);
      final ilstEnd = min(ilstOffset + ilstSize, moovBytes.length);

      int itemPos = ilstOffset + 8; // skip ilst header
      while (itemPos + 8 <= ilstEnd) {
        final itemSize = _readUint32BE(moovBytes, itemPos);
        if (itemSize < 8 || itemPos + itemSize > ilstEnd) break;
        final itemName = String.fromCharCodes(moovBytes.sublist(itemPos + 4, itemPos + 8));

        // Inside each metadata item is a 'data' atom
        int dataPos = itemPos + 8;
        while (dataPos + 8 <= itemPos + itemSize) {
          final dataSize = _readUint32BE(moovBytes, dataPos);
          if (dataSize < 8 || dataPos + dataSize > itemPos + itemSize) break;
          final dataName = String.fromCharCodes(moovBytes.sublist(dataPos + 4, dataPos + 8));

          if (dataName == 'data' && dataSize >= 16) {
            // Flags at dataPos + 8 (4 bytes): 1 = UTF-8 text, 13/14 = JPEG/PNG
            final flags = _readUint32BE(moovBytes, dataPos + 8);
            final payload = moovBytes.sublist(dataPos + 16, dataPos + dataSize);

            if (itemName == '\xa9nam' || itemName == 'titl') {
              title = utf8.decode(payload, allowMalformed: true).trim();
            } else if (itemName == '\xa9ART' || itemName == 'aART' || itemName == 'art') {
              artist ??= utf8.decode(payload, allowMalformed: true).trim();
            } else if (itemName == '\xa9alb' || itemName == 'alb') {
              album = utf8.decode(payload, allowMalformed: true).trim();
            } else if (itemName == 'trkn' && payload.length >= 4) {
              trackNumber = (payload[2] << 8) | payload[3];
            } else if (itemName == 'covr' && extractPicture && pictureBytes == null) {
              pictureBytes = payload;
              pictureMime = (flags == 14) ? 'image/png' : 'image/jpeg';
            }
            break;
          }
          dataPos += dataSize;
        }

        itemPos += itemSize;
      }
    } catch (_) {}

    return (
      title: title,
      artist: artist,
      album: album,
      trackNumber: trackNumber,
      pictureBytes: pictureBytes,
      pictureMime: pictureMime,
    );
  }

  // ===========================================================================
  // MP3 / ID3v2 Parser
  // ===========================================================================

  static SafeAudioMetadata? _readId3Metadata(
    File file, {
    required bool extractPicture,
  }) {
    RandomAccessFile? raf;
    try {
      if (!file.existsSync()) return null;
      raf = file.openSync(mode: FileMode.read);
      final fileLength = raf.lengthSync();
      if (fileLength < 10) return null;

      final header = raf.readSync(10);
      if (header.length < 10) return null;

      // Verify ID3 marker
      if (header[0] != 0x49 || header[1] != 0x44 || header[2] != 0x33) {
        return null;
      }

      final version = header[3]; // ID3v2.3 or ID3v2.4
      final tagSize = _readSyncSafeInt(header, 6);
      if (tagSize <= 0) return null;

      // Read ID3 tag payload (bound to max 5MB)
      final readSize = min(tagSize, min(fileLength - 10, 5 * 1024 * 1024));
      final tagBytes = raf.readSync(readSize);

      String? title;
      String? artist;
      String? album;
      Duration? duration;
      int? trackNumber;
      Uint8List? pictureBytes;
      String? pictureMime;

      int offset = 0;
      final isV4 = version >= 4;

      while (offset + 10 <= tagBytes.length) {
        // Frame ID (4 bytes)
        final frameId = String.fromCharCodes(tagBytes.sublist(offset, offset + 4));
        if (frameId.codeUnits.any((c) => c < 0x20 || c > 0x7E)) {
          // Reached padding/zeros at end of ID3 tag
          break;
        }

        // Frame Size
        final frameSize = isV4
            ? _readSyncSafeInt(tagBytes, offset + 4)
            : _readUint32BE(tagBytes, offset + 4);

        offset += 10; // skip frame header

        if (frameSize <= 0 || offset + frameSize > tagBytes.length) {
          break;
        }

        final framePayload = tagBytes.sublist(offset, offset + frameSize);
        offset += frameSize;

        if (framePayload.isEmpty) continue;

        switch (frameId) {
          case 'TIT2': // Title
            title ??= _decodeId3Text(framePayload);
            break;
          case 'TPE1': // Artist
          case 'TPE2': // Album Artist
            artist ??= _decodeId3Text(framePayload);
            break;
          case 'TALB': // Album
            album ??= _decodeId3Text(framePayload);
            break;
          case 'TRCK': // Track number
            final trkStr = _decodeId3Text(framePayload);
            if (trkStr != null) {
              final clean = trkStr.split('/').first.trim();
              trackNumber ??= int.tryParse(clean);
            }
            break;
          case 'TLEN': // Duration in milliseconds
            final lenStr = _decodeId3Text(framePayload);
            if (lenStr != null) {
              final ms = int.tryParse(lenStr);
              if (ms != null && ms > 0) {
                duration = Duration(milliseconds: ms);
              }
            }
            break;
          case 'APIC': // Attached picture
            if (extractPicture && pictureBytes == null) {
              final pic = _decodeId3Apic(framePayload);
              if (pic != null) {
                pictureBytes = pic.bytes;
                pictureMime = pic.mime;
              }
            }
            break;
        }
      }

      return SafeAudioMetadata(
        title: title,
        artist: artist,
        album: album,
        duration: duration,
        trackNumber: trackNumber,
        pictureBytes: pictureBytes,
        pictureMime: pictureMime,
      );
    } catch (_) {
      return null;
    } finally {
      try {
        raf?.closeSync();
      } catch (_) {}
    }
  }

  static String? _decodeId3Text(Uint8List frameBytes) {
    if (frameBytes.isEmpty) return null;
    final encoding = frameBytes[0];
    final data = frameBytes.sublist(1);

    try {
      switch (encoding) {
        case 0: // ISO-8859-1 / Latin1
          return latin1.decode(data).replaceAll('\x00', '').trim();
        case 1: // UTF-16 with BOM
        case 2: // UTF-16BE without BOM
          // Fallback to UTF-16 or UTF-8 if available
          return _decodeUtf16(data).replaceAll('\x00', '').trim();
        case 3: // UTF-8
        default:
          return utf8
              .decode(data, allowMalformed: true)
              .replaceAll('\x00', '')
              .trim();
      }
    } catch (_) {
      return null;
    }
  }

  static String _decodeUtf16(Uint8List data) {
    if (data.length < 2) return '';
    try {
      final buffer = StringBuffer();
      // Detect BOM: 0xFF 0xFE = LE, 0xFE 0xFF = BE
      bool isBE = false;
      int start = 0;
      if (data[0] == 0xFE && data[1] == 0xFF) {
        isBE = true;
        start = 2;
      } else if (data[0] == 0xFF && data[1] == 0xFE) {
        isBE = false;
        start = 2;
      }

      for (int i = start; i + 1 < data.length; i += 2) {
        final code = isBE
            ? (data[i] << 8) | data[i + 1]
            : (data[i + 1] << 8) | data[i];
        if (code != 0) {
          buffer.writeCharCode(code);
        }
      }
      return buffer.toString();
    } catch (_) {
      return '';
    }
  }

  static ({Uint8List bytes, String mime})? _decodeId3Apic(Uint8List payload) {
    if (payload.length < 10) return null;
    try {
      int offset = 1; // skip encoding byte

      // MIME type is null-terminated ASCII
      final mimeStart = offset;
      while (offset < payload.length && payload[offset] != 0) {
        offset++;
      }
      final mime = latin1.decode(payload.sublist(mimeStart, offset));
      offset++; // skip null terminator

      if (offset >= payload.length) return null;
      // Picture type (1 byte)
      offset++;

      // Description (null-terminated string, may be 1 or 2 nulls depending on encoding)
      while (offset < payload.length && payload[offset] != 0) {
        offset++;
      }
      while (offset < payload.length && payload[offset] == 0) {
        offset++;
      }

      if (offset >= payload.length) return null;
      final picBytes = payload.sublist(offset);
      return (bytes: picBytes, mime: mime.isNotEmpty ? mime : 'image/jpeg');
    } catch (_) {
      return null;
    }
  }

  // ===========================================================================
  // Header-based Auto Detection
  // ===========================================================================

  static SafeAudioMetadata? _detectAndReadByHeader(
    File file, {
    required bool extractPicture,
  }) {
    RandomAccessFile? raf;
    try {
      if (!file.existsSync()) return null;
      raf = file.openSync(mode: FileMode.read);
      if (raf.lengthSync() < 8) return null;
      final magic = raf.readSync(8);
      raf.closeSync();
      raf = null;

      if (magic.length >= 4) {
        // FLAC
        if (magic[0] == 0x66 && magic[1] == 0x4C && magic[2] == 0x61 && magic[3] == 0x43) {
          return _readFlacMetadata(file, extractPicture: extractPicture);
        }
        // ID3v2
        if (magic[0] == 0x49 && magic[1] == 0x44 && magic[2] == 0x33) {
          // Could be MP3 or FLAC with ID3 header:
          final flacAttempt = _readFlacMetadata(file, extractPicture: extractPicture);
          if (flacAttempt != null && flacAttempt.hasBasicMetadata) {
            return flacAttempt;
          }
          return _readId3Metadata(file, extractPicture: extractPicture);
        }
        // OGG
        if (magic[0] == 0x4F && magic[1] == 0x67 && magic[2] == 0x67 && magic[3] == 0x53) {
          return null; // Let filename fallback handle OGG safely
        }
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      try {
        raf?.closeSync();
      } catch (_) {}
    }
  }

  // ===========================================================================
  // Binary Utility Helpers
  // ===========================================================================

  static int _readSyncSafeInt(List<int> bytes, int offset) {
    return ((bytes[offset] & 0x7F) << 21) |
        ((bytes[offset + 1] & 0x7F) << 14) |
        ((bytes[offset + 2] & 0x7F) << 7) |
        (bytes[offset + 3] & 0x7F);
  }

  static int _readUint32BE(List<int> bytes, int offset) {
    return (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
  }

  static int _readUint32LE(List<int> bytes, int offset) {
    return bytes[offset] |
        (bytes[offset + 1] << 8) |
        (bytes[offset + 2] << 16) |
        (bytes[offset + 3] << 24);
  }

  static int _readUint64BE(List<int> bytes, int offset) {
    return (bytes[offset] << 56) |
        (bytes[offset + 1] << 48) |
        (bytes[offset + 2] << 40) |
        (bytes[offset + 3] << 32) |
        (bytes[offset + 4] << 24) |
        (bytes[offset + 5] << 16) |
        (bytes[offset + 6] << 8) |
        bytes[offset + 7];
  }
}
