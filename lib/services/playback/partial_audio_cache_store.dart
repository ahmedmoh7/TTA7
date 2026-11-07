import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Persistent index of independently stored, complete byte ranges.
class PartialAudioCacheStore {
  PartialAudioCacheStore(this.file) : _indexFile = File('${file.path}.ranges.json');

  final File file;
  final File _indexFile;
  final List<({int start, int end, String path})> _ranges = [];

  // Serialize index mutations across store instances for the same cache key.
  static final Map<String, Future<void>> _writeLocks = {};

  Future<void> load() async {
    _ranges.clear();
    try {
      if (!await _indexFile.exists()) return;
      final decoded = jsonDecode(await _indexFile.readAsString());
      if (decoded is! Map<String, dynamic> || decoded['ranges'] is! List) return;
      for (final item in decoded['ranges'] as List) {
        if (item is! Map) continue;
        final start = item['start'], end = item['end'], path = item['path'];
        if (start is int && end is int && path is String && start >= 0 &&
            end > start && await File(path).exists()) {
          _ranges.add((start: start, end: end, path: path));
        }
      }
      _ranges.sort((a, b) => a.start.compareTo(b.start));
    } catch (_) {
      _ranges.clear();
    }
  }

  bool contains(int start, int end) {
    var cursor = start;
    for (final range in _ranges) {
      if (range.end <= cursor) continue;
      if (range.start > cursor) return false;
      if (range.end > cursor) cursor = range.end;
      if (cursor >= end) return true;
    }
    return false;
  }

  Future<void> writeRange(int start, Stream<List<int>> bytes) async {
    if (start < 0) throw RangeError.value(start, 'start');
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.range.$start.${DateTime.now().microsecondsSinceEpoch}.${identityHashCode(this)}.tmp');
    final sink = temp.openWrite();
    var length = 0;
    try {
      await for (final chunk in bytes) {
        sink.add(chunk);
        length += chunk.length;
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (length == 0) {
      if (await temp.exists()) await temp.delete();
      return;
    }

    final end = start + length;
    await _withWriteLock(() async {
      // Reload inside the lock so writes from another source instance are not lost.
      await load();
      final target = File('${file.path}.range.$start.$end');
      if (await target.exists()) await target.delete();
      await temp.rename(target.path);
      _ranges.removeWhere((r) => r.start == start && r.end == end);
      _ranges.add((start: start, end: end, path: target.path));
      _ranges.sort((a, b) => a.start.compareTo(b.start));
      await _saveIndex();
    });
  }

  Future<void> _withWriteLock(Future<void> Function() action) async {
    final key = file.path;
    final previous = _writeLocks[key] ?? Future<void>.value();
    final done = Completer<void>();
    _writeLocks[key] = done.future;
    try {
      await previous;
      await action();
    } finally {
      done.complete();
      if (identical(_writeLocks[key], done.future)) _writeLocks.remove(key);
    }
  }

  Future<Stream<List<int>>> readRange(int start, int end) async {
    await load();
    if (!contains(start, end)) throw StateError('Requested bytes are not fully cached');
    final segments = <({String path, int from, int to})>[];
    var cursor = start;
    for (final range in _ranges) {
      if (range.end <= cursor) continue;
      if (range.start > cursor) break;
      final segmentEnd = range.end < end ? range.end : end;
      segments.add((path: range.path, from: cursor - range.start, to: segmentEnd - range.start));
      cursor = segmentEnd;
      if (cursor >= end) break;
    }
    return _readSegments(segments);
  }

  Stream<List<int>> _readSegments(List<({String path, int from, int to})> segments) async* {
    for (final segment in segments) {
      final handle = await File(segment.path).open();
      try {
        await handle.setPosition(segment.from);
        var remaining = segment.to - segment.from;
        while (remaining > 0) {
          final chunk = await handle.read(remaining < 65536 ? remaining : 65536);
          if (chunk.isEmpty) throw FileSystemException('Cached range file truncated', segment.path);
          remaining -= chunk.length;
          yield chunk;
        }
      } finally {
        await handle.close();
      }
    }
  }

  Future<void> _saveIndex() async => _indexFile.writeAsString(jsonEncode({
    'version': 1,
    'ranges': _ranges.map((r) => {'start': r.start, 'end': r.end, 'path': r.path}).toList(),
  }), flush: true);

  Future<void> clear() async {
    await _withWriteLock(() async {
      await load();
      for (final range in _ranges) {
        final cached = File(range.path);
        if (await cached.exists()) await cached.delete();
      }
      _ranges.clear();
      if (await _indexFile.exists()) await _indexFile.delete();
      if (await file.exists()) await file.delete();
    });
  }
}
