import 'dart:convert';
import 'dart:typed_data';

/// References a box (atom) in an MP4 file
class _BoxRef {
  final int offset;
  final int headerLen;
  final int size;
  final int rawSize32;
  final String type;

  const _BoxRef({
    required this.offset,
    required this.headerLen,
    required this.size,
    required this.rawSize32,
    required this.type,
  });

  int get contentOffset => offset + headerLen;
  int get end => offset + size;
}

/// Writes iTunes-style metadata atoms (title, artist, album, lyrics, cover)
/// into an M4A / MP4 file in-place, updating chunk offsets (`stco`/`co64`).
class Mp4Tagger {
  static const Set<String> _containers = {
    'moov',
    'trak',
    'mdia',
    'minf',
    'stbl',
  };

  /// Tag M4A/MP4 bytes with metadata.
  /// Returns the tagged bytes, or original bytes if parsing/tagging fails.
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
      final items = <Uint8List>[];

      if (title != null && title.trim().isNotEmpty) {
        items.add(_textItem('©nam', title.trim()));
      }
      if (artist != null && artist.trim().isNotEmpty) {
        items.add(_textItem('©ART', artist.trim()));
      }
      if (album != null && album.trim().isNotEmpty) {
        items.add(_textItem('©alb', album.trim()));
      }
      if (lyrics != null && lyrics.trim().isNotEmpty) {
        items.add(_textItem('©lyr', lyrics.trim()));
      }
      if (coverBytes != null && coverBytes.isNotEmpty) {
        items.add(_coverItem(coverBytes, coverIsPng));
      }

      if (items.isEmpty) return bytes;

      final boxes = _parseBoxes(bytes, 0, bytes.length);
      final moov = boxes.cast<_BoxRef?>().firstWhere(
        (b) => b?.type == 'moov',
        orElse: () => null,
      );

      if (moov == null) return bytes;

      final udta = _udtaAtom(_metaAtom(_ilstAtom(items)));
      return _insert(bytes, moov, udta);
    } catch (_) {
      return bytes;
    }
  }

  static Uint8List _insert(Uint8List bytes, _BoxRef moov, Uint8List udta) {
    final insertAt = moov.end;
    final delta = udta.length;

    // Create prefix copy that we can modify
    final prefix = Uint8List.fromList(bytes.sublist(0, insertAt));

    // If moov size is not running to end of file, update moov header size
    if (moov.rawSize32 != 0) {
      if (moov.headerLen == 16) {
        _writeU64(prefix, moov.offset + 8, moov.size + delta);
      } else {
        _writeU32(prefix, moov.offset, moov.size + delta);
      }
    }

    // Collect all offset boxes (stco, co64) in moov and adjust them
    final offsetBoxes = <_BoxRef>[];
    _collectOffsetBoxes(bytes, moov, offsetBoxes);

    for (final box in offsetBoxes) {
      if (box.type == 'stco') {
        _patchStco(prefix, box, insertAt, delta);
      } else if (box.type == 'co64') {
        _patchCo64(prefix, box, insertAt, delta);
      }
    }

    final suffix = bytes.sublist(insertAt);

    final result = Uint8List(prefix.length + udta.length + suffix.length);
    result.setRange(0, prefix.length, prefix);
    result.setRange(prefix.length, prefix.length + udta.length, udta);
    result.setRange(prefix.length + udta.length, result.length, suffix);
    return result;
  }

  static void _collectOffsetBoxes(
    Uint8List bytes,
    _BoxRef box,
    List<_BoxRef> out,
  ) {
    if (box.type == 'stco' || box.type == 'co64') {
      out.add(box);
      return;
    }
    if (_containers.contains(box.type)) {
      final children = _parseBoxes(bytes, box.contentOffset, box.end);
      for (final child in children) {
        _collectOffsetBoxes(bytes, child, out);
      }
    }
  }

  /// `stco`: FullBox header (4 bytes), entry count (4 bytes), then 32-bit offsets.
  static void _patchStco(
    Uint8List bytes,
    _BoxRef box,
    int insertAt,
    int delta,
  ) {
    final base = box.contentOffset + 4; // Skip version/flags
    if (base + 4 > bytes.length) return;
    final count = _readU32(bytes, base);
    var p = base + 4;
    for (var i = 0; i < count; i++) {
      if (p + 4 > bytes.length) break;
      final off = _readU32(bytes, p);
      if (off >= insertAt) {
        _writeU32(bytes, p, off + delta);
      }
      p += 4;
    }
  }

  /// `co64`: FullBox header (4 bytes), entry count (4 bytes), then 64-bit offsets.
  static void _patchCo64(
    Uint8List bytes,
    _BoxRef box,
    int insertAt,
    int delta,
  ) {
    final base = box.contentOffset + 4; // Skip version/flags
    if (base + 4 > bytes.length) return;
    final count = _readU32(bytes, base);
    var p = base + 4;
    for (var i = 0; i < count; i++) {
      if (p + 8 > bytes.length) break;
      final off = _readU64(bytes, p);
      if (off >= insertAt) {
        _writeU64(bytes, p, off + delta);
      }
      p += 8;
    }
  }

  static List<_BoxRef> _parseBoxes(Uint8List bytes, int start, int end) {
    final out = <_BoxRef>[];
    var pos = start;

    while (pos + 8 <= end) {
      final size32 = _readU32(bytes, pos);
      final type = latin1.decode(bytes.sublist(pos + 4, pos + 8));
      var headerLen = 8;
      var size = size32;

      if (size32 == 1) {
        if (pos + 16 > end) break;
        size = _readU64(bytes, pos + 8);
        headerLen = 16;
      } else if (size32 == 0) {
        size = end - pos;
      }

      if (size < headerLen || pos + size > end || size > 0x7FFFFFFF) break;
      out.add(
        _BoxRef(
          offset: pos,
          headerLen: headerLen,
          size: size,
          rawSize32: size32,
          type: type,
        ),
      );
      pos += size;
    }
    return out;
  }

  static int _readU32(Uint8List b, int off) {
    return ((b[off] & 0xFF) << 24) |
        ((b[off + 1] & 0xFF) << 16) |
        ((b[off + 2] & 0xFF) << 8) |
        (b[off + 3] & 0xFF);
  }

  static int _readU64(Uint8List b, int off) {
    var v = 0;
    for (var i = 0; i < 8; i++) {
      v = (v << 8) | (b[off + i] & 0xFF);
    }
    return v;
  }

  static void _writeU32(Uint8List b, int off, int value) {
    b[off] = (value >> 24) & 0xFF;
    b[off + 1] = (value >> 16) & 0xFF;
    b[off + 2] = (value >> 8) & 0xFF;
    b[off + 3] = value & 0xFF;
  }

  static void _writeU64(Uint8List b, int off, int value) {
    for (var i = 0; i < 8; i++) {
      b[off + i] = (value >> (8 * (7 - i))) & 0xFF;
    }
  }

  static Uint8List _box(String type, Uint8List payload) {
    final out = Uint8List(8 + payload.length);
    _writeU32(out, 0, 8 + payload.length);
    final typeBytes = latin1.encode(type);
    out.setRange(4, 8, typeBytes);
    out.setRange(8, 8 + payload.length, payload);
    return out;
  }

  static Uint8List _dataAtom(int typeIndicator, Uint8List payload) {
    final body = Uint8List(8 + payload.length);
    _writeU32(body, 0, typeIndicator);
    // Bytes 4..7 are locale/flags (0)
    body.setRange(8, 8 + payload.length, payload);
    return _box('data', body);
  }

  static Uint8List _textItem(String fourCc, String text) {
    return _box(fourCc, _dataAtom(1, utf8.encode(text)));
  }

  static Uint8List _coverItem(Uint8List image, bool isPng) {
    return _box('covr', _dataAtom(isPng ? 14 : 13, image));
  }

  static Uint8List _hdlrAtom() {
    final body = Uint8List(25);
    // bytes 8..11 handler_type = "mdir"
    final mdir = latin1.encode('mdir');
    body.setRange(8, 12, mdir);
    return _box('hdlr', body);
  }

  static Uint8List _ilstAtom(List<Uint8List> items) {
    final totalLen = items.fold<int>(0, (sum, item) => sum + item.length);
    final payload = Uint8List(totalLen);
    var p = 0;
    for (final item in items) {
      payload.setRange(p, p + item.length, item);
      p += item.length;
    }
    return _box('ilst', payload);
  }

  static Uint8List _metaAtom(Uint8List ilst) {
    final hdlr = _hdlrAtom();
    final payload = Uint8List(4 + hdlr.length + ilst.length);
    // bytes 0..3: version/flags (0)
    payload.setRange(4, 4 + hdlr.length, hdlr);
    payload.setRange(4 + hdlr.length, payload.length, ilst);
    return _box('meta', payload);
  }

  static Uint8List _udtaAtom(Uint8List meta) => _box('udta', meta);
}
