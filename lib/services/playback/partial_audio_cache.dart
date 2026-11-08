import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:just_audio/just_audio.dart';

// ignore_for_file: experimental_member_use

/// An HTTP representation used by [PartialCachingAudioSource].
///
/// [representationKey] identifies stable media (track, provider, rendition and
/// quality); it must never contain a signed/temporary stream URL.
class PartialAudioOrigin {
  const PartialAudioOrigin({
    required this.uri,
    required this.representationKey,
    required this.contentType,
    this.headers = const <String, String>{},
    this.contentLength,
  });

  final Uri uri;
  final String representationKey;
  final String contentType;
  final Map<String, String> headers;
  final int? contentLength;
}

typedef PartialAudioOriginRefresh = Future<PartialAudioOrigin?> Function();
typedef PartialAudioCacheComplete = FutureOr<void> Function(File audioFile);

/// A validated summary of byte ranges persisted for one audio representation.
class PartialAudioCacheSnapshot {
  const PartialAudioCacheSnapshot({
    required this.totalLength,
    required this.contentType,
    required this.cachedBytes,
    required this.lastAccessMs,
  });

  final int? totalLength;
  final String contentType;
  final int cachedBytes;
  final int lastAccessMs;
}

/// Streams a progressive media file from validated cached byte ranges and asks
/// the origin only for missing ranges. It never starts an independent,
/// background full-file download. HLS/DASH manifests must stay on their native
/// segment-aware sources rather than being treated as one progressive file.
class PartialCachingAudioSource extends StreamAudioSource {
  PartialCachingAudioSource({
    required PartialAudioOrigin origin,
    required this.audioFile,
    required int? expectedLength,
    PartialAudioOriginRefresh? refreshOrigin,
    PartialAudioCacheComplete? onComplete,
    this.rangeChunkBytes = 512 * 1024,
    this.offlineOnly = false,
    super.tag,
  }) : _origin = origin,
       _expectedLength = expectedLength,
       _refreshOrigin = refreshOrigin,
       _onComplete = onComplete,
       _store = PartialAudioCacheStore(audioFile) {
    if (rangeChunkBytes < 4096) {
      throw ArgumentError.value(rangeChunkBytes, 'rangeChunkBytes');
    }
  }

  static final HttpClient _httpClient = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20);

  final File audioFile;
  final int rangeChunkBytes;
  /// When true, missing byte ranges fail locally and never contact the origin.
  final bool offlineOnly;
  final int? _expectedLength;
  final PartialAudioOriginRefresh? _refreshOrigin;
  final PartialAudioCacheComplete? _onComplete;
  final PartialAudioCacheStore _store;
  PartialAudioOrigin _origin;
  bool _completionNotified = false;

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    if (start != null && start < 0) throw RangeError.value(start, 'start');
    if (end != null && end < 0) throw RangeError.value(end, 'end');
    if (start != null && end != null && end <= start) {
      throw RangeError('The end of an audio byte range must follow its start.');
    }

    var meta = await _store._read(
      expectedLength: _expectedLength,
      fallbackContentType: _origin.contentType,
    );
    var total = meta.totalLength ?? _origin.contentLength ?? _expectedLength;
    if (meta.totalLength == null && total != null) {
      await _store.updateTotalLength(total);
      meta = await _store._read(
        expectedLength: _expectedLength,
        fallbackContentType: _origin.contentType,
      );
    }

    final isRangeRequest = start != null;
    final outputStart = start ?? 0;
    if (total != null && outputStart >= total) {
      throw RangeError(
        'Requested audio range starts past the end of the file.',
      );
    }
    var outputEnd = end ?? total;
    if (total != null && outputEnd != null) {
      outputEnd = math.min(outputEnd, total);
    }

    if (total != null && await _store.isComplete(total)) {
      await _store.touch();
      return StreamAudioResponse(
        rangeRequestsSupported: true,
        sourceLength: total,
        contentLength: (outputEnd ?? total) - outputStart,
        offset: isRangeRequest ? outputStart : null,
        contentType: meta.contentType,
        stream: _store.readStream(outputStart, outputEnd ?? total),
      );
    }

    // Offline replay may use only the exact ranges already persisted. Never
    // attempt a network request or refresh a signed URL in this mode.
    if (offlineOnly) {
      final cachedEnd = await _store.cachedEndFrom(
        outputStart,
        limit: outputEnd,
      );
      if (cachedEnd == null || cachedEnd <= outputStart) {
        throw HttpException(
          'Requested audio bytes are not available in the offline cache.',
          uri: _origin.uri,
        );
      }
      await _store.touch();
      return StreamAudioResponse(
        rangeRequestsSupported: true,
        sourceLength: total,
        contentLength: cachedEnd - outputStart,
        offset: isRangeRequest ? outputStart : null,
        contentType: meta.contentType.isEmpty
            ? _origin.contentType
            : meta.contentType,
        stream: _store.readStream(outputStart, cachedEnd),
      );
    }

    // Learn whether the origin really supports byte ranges before telling the
    // local player proxy. Reuse this first response: a 200 body is streamed
    // progressively to the player and cache, not discarded and fetched again.
    if (meta.rangeSupported == null) {
      final release = await _store.acquireWriteLock();
      try {
        final firstEnd = math.min(
          outputEnd ?? _chunkBoundaryEnd(outputStart),
          _chunkBoundaryEnd(outputStart),
        );
        final prepared = await _openRange(
          outputStart,
          firstEnd,
          storeLockHeld: true,
        );
        if (prepared.isWholeResponse) {
          release();
          return _wholeResponse(prepared);
        }
        total = prepared.totalLength ?? await _store.totalLength();
        if (total == null && end == null) {
          await prepared.close();
          release();
          // A 206 with `Content-Range: .../*` cannot describe an open-ended
          // local 206 response. Fall back to one progressive full GET instead.
          return _wholeResponse(await _openFullResponse());
        }
        if (total != null) {
          outputEnd = outputEnd == null ? total : math.min(outputEnd, total);
        }
        final resolvedEnd = outputEnd;
        return StreamAudioResponse(
          rangeRequestsSupported: true,
          sourceLength: total,
          contentLength: resolvedEnd == null ? null : resolvedEnd - outputStart,
          offset: isRangeRequest ? outputStart : null,
          contentType: prepared.contentType,
          stream: _streamRequestedRange(
            outputStart,
            resolvedEnd,
            firstResponse: prepared,
            firstResponseLockRelease: release,
          ),
        );
      } catch (_) {
        release();
        rethrow;
      }
    }

    // An open-ended native Range needs its final content length in just_audio's
    // proxy response. When metadata has no total, learn it from this requested
    // range before returning the 206 response. The range body remains pending
    // and is streamed/cached as the player consumes it.
    if (isRangeRequest && end == null && total == null) {
      final release = await _store.acquireWriteLock();
      try {
        final prepared = await _openRange(
          outputStart,
          outputStart + rangeChunkBytes,
          storeLockHeld: true,
        );
        if (prepared.isWholeResponse) {
          release();
          return _wholeResponse(prepared);
        }
        total = prepared.totalLength ?? await _store.totalLength();
        if (total == null) {
          await prepared.close();
          release();
          return _wholeResponse(await _openFullResponse());
        }
        if (outputStart >= total) {
          await prepared.close();
          release();
          throw RangeError(
            'Requested audio range starts past the end of the file.',
          );
        }
        return StreamAudioResponse(
          rangeRequestsSupported: true,
          sourceLength: total,
          contentLength: total - outputStart,
          offset: outputStart,
          contentType: prepared.contentType,
          stream: _streamRequestedRange(
            outputStart,
            total,
            firstResponse: prepared,
            firstResponseLockRelease: release,
          ),
        );
      } catch (_) {
        release();
        rethrow;
      }
    }

    final resolvedEnd = outputEnd;
    return StreamAudioResponse(
      rangeRequestsSupported: meta.rangeSupported ?? true,
      sourceLength: total,
      contentLength: resolvedEnd == null ? null : resolvedEnd - outputStart,
      offset: isRangeRequest ? outputStart : null,
      contentType: meta.contentType,
      stream: _streamRequestedRange(outputStart, resolvedEnd),
    );
  }

  Stream<List<int>> _streamRequestedRange(
    int start,
    int? end, {
    _PreparedAudioResponse? firstResponse,
    void Function()? firstResponseLockRelease,
  }) async* {
    var cursor = start;
    var pending = firstResponse;
    var pendingRelease = firstResponseLockRelease;
    try {
      while (end == null || cursor < end) {
        final total = await _store.totalLength() ?? _expectedLength;
        if (total != null && cursor >= total) break;
        final limit = end == null
            ? _chunkBoundaryEnd(cursor)
            : math.min(end, _chunkBoundaryEnd(cursor));

        var meta = await _store._read(
          expectedLength: _expectedLength,
          fallbackContentType: _origin.contentType,
        );
        final coveredEnd = _coveredEndAt(meta.ranges, cursor);
        if (coveredEnd != null) {
          final readEnd = math.min(limit, coveredEnd);
          if (readEnd <= cursor) break;
          await _store.touch();
          yield* _store.readStream(cursor, readEnd);
          cursor = readEnd;
          continue;
        }

        var gapEnd = limit;
        for (final range in meta.ranges) {
          if (range.start > cursor) {
            gapEnd = math.min(gapEnd, range.start);
            break;
          }
        }
        if (gapEnd <= cursor) break;

        final release = pendingRelease ?? await _store.acquireWriteLock();
        pendingRelease = null;
        try {
          // Another player/seek may have filled this gap while we waited.
          meta = await _store._read(
            expectedLength: _expectedLength,
            fallbackContentType: _origin.contentType,
          );
          final nowCovered = _coveredEndAt(meta.ranges, cursor);
          if (nowCovered != null) {
            final readEnd = math.min(limit, nowCovered);
            yield* _store.readStream(cursor, readEnd);
            cursor = readEnd;
            continue;
          }

          gapEnd = limit;
          for (final range in meta.ranges) {
            if (range.start > cursor) {
              gapEnd = math.min(gapEnd, range.start);
              break;
            }
          }
          final prepared =
              pending != null && pending.isRange && pending.start == cursor
              ? pending
              : await _openRange(cursor, gapEnd, storeLockHeld: true);
          if (identical(prepared, pending)) pending = null;

          if (prepared.isWholeResponse) {
            // The server ignored Range or changed its behavior. Consume that
            // one full response, persist bytes sequentially and yield only the
            // requested interval. There is no efficient random-range fallback
            // when the origin does not implement Range.
            await for (final chunk in _consumeWholeResponseSlice(
              prepared,
              sliceStart: cursor,
              sliceEnd: end,
              storeLockHeld: true,
            )) {
              yield chunk;
            }
            return;
          }

          if (prepared.start > cursor) {
            await prepared.close();
            throw FormatException('Origin skipped requested audio bytes.');
          }
          if (prepared.start < cursor) {
            await prepared.close();
            throw FormatException('Origin returned an overlapping byte range.');
          }

          var fetchedOffset = prepared.start;
          var fetchedBytes = 0;
          final iterator = StreamIterator<List<int>>(prepared.response);
          try {
            while (await iterator.moveNext()) {
              final chunk = iterator.current;
              if (chunk.isEmpty) continue;
              await _store.writeBytes(
                fetchedOffset,
                chunk,
                totalLength: prepared.totalLength,
                contentType: prepared.contentType,
                etag: prepared.etag,
                lastModified: prepared.lastModified,
                storeLockHeld: true,
              );
              fetchedOffset += chunk.length;
              fetchedBytes += chunk.length;
              yield chunk;
              await _notifyIfComplete(prepared.totalLength);
            }
          } finally {
            await iterator.cancel();
          }

          final promisedLength = prepared.end! - prepared.start;
          if (fetchedBytes != promisedLength) {
            throw FormatException(
              'Origin range ended after $fetchedBytes bytes; expected $promisedLength.',
            );
          }
          cursor = fetchedOffset;
        } finally {
          release();
        }
      }
    } finally {
      if (pendingRelease != null) pendingRelease();
      if (pending != null) await pending.close();
    }
  }

  int _chunkBoundaryEnd(int offset) =>
      ((offset ~/ rangeChunkBytes) + 1) * rangeChunkBytes;

  Future<_PreparedAudioResponse> _openRange(
    int start,
    int end, {
    bool storeLockHeld = false,
  }) async {
    var refreshAttempts = 0;
    while (true) {
      final request = await _httpClient.getUrl(_origin.uri);
      _setRequestHeaders(request);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-${end - 1}');
      final metadata = await _store._read(
        expectedLength: _expectedLength,
        fallbackContentType: _origin.contentType,
      );
      final validator = metadata.etag ?? metadata.lastModified;
      if (validator != null && validator.isNotEmpty) {
        request.headers.set(HttpHeaders.ifRangeHeader, validator);
      }

      final response = await request.close();
      final responseType =
          response.headers.value(HttpHeaders.contentTypeHeader) ??
          _origin.contentType;
      if (response.statusCode == HttpStatus.partialContent) {
        final parsed = _ParsedContentRange.parse(
          response.headers.value(HttpHeaders.contentRangeHeader),
        );
        if (parsed == null || parsed.start != start || parsed.end <= start) {
          await response.drain<void>();
          throw FormatException(
            'Origin returned HTTP 206 without a matching Content-Range.',
          );
        }
        if (parsed.end > end) {
          await response.drain<void>();
          throw FormatException(
            'Origin returned bytes outside the requested range.',
          );
        }
        await _store.updateOrigin(
          originFingerprint: _origin.representationKey,
          totalLength: parsed.total,
          contentType: responseType,
          etag: response.headers.value(HttpHeaders.etagHeader),
          lastModified: response.headers.value(HttpHeaders.lastModifiedHeader),
          rangeSupported: true,
          storeLockHeld: storeLockHeld,
        );
        return _PreparedAudioResponse.range(
          response,
          start: parsed.start,
          end: parsed.end,
          totalLength: parsed.total,
          contentType: responseType,
        );
      }

      if (response.statusCode == HttpStatus.ok) {
        final length = response.contentLength > 0
            ? response.contentLength
            : _expectedLength;
        await _store.updateOrigin(
          originFingerprint: _origin.representationKey,
          totalLength: length,
          contentType: responseType,
          etag: response.headers.value(HttpHeaders.etagHeader),
          lastModified: response.headers.value(HttpHeaders.lastModifiedHeader),
          rangeSupported: false,
          storeLockHeld: storeLockHeld,
        );
        return _PreparedAudioResponse.whole(
          response,
          totalLength: length,
          contentType: responseType,
        );
      }

      if (_isExpiredStatus(response.statusCode) &&
          refreshAttempts == 0 &&
          _refreshOrigin != null) {
        await response.drain<void>();
        final fresh = await _refreshOrigin();
        if (fresh != null &&
            fresh.representationKey == _origin.representationKey) {
          _origin = fresh;
          refreshAttempts++;
          continue;
        }
      }

      final status = response.statusCode;
      await response.drain<void>();
      throw HttpException('Audio range request failed with HTTP $status.');
    }
  }

  Future<_PreparedAudioResponse> _openFullResponse() async {
    var refreshAttempts = 0;
    while (true) {
      final request = await _httpClient.getUrl(_origin.uri);
      _setRequestHeaders(request);
      final response = await request.close();
      final responseType =
          response.headers.value(HttpHeaders.contentTypeHeader) ??
          _origin.contentType;
      if (response.statusCode == HttpStatus.ok) {
        final length = response.contentLength > 0
            ? response.contentLength
            : _expectedLength;
        await _store.updateOrigin(
          originFingerprint: _origin.representationKey,
          totalLength: length,
          contentType: responseType,
          etag: response.headers.value(HttpHeaders.etagHeader),
          lastModified: response.headers.value(HttpHeaders.lastModifiedHeader),
          rangeSupported: false,
        );
        return _PreparedAudioResponse.whole(
          response,
          totalLength: length,
          contentType: responseType,
        );
      }
      if (_isExpiredStatus(response.statusCode) &&
          refreshAttempts == 0 &&
          _refreshOrigin != null) {
        await response.drain<void>();
        final fresh = await _refreshOrigin();
        if (fresh != null &&
            fresh.representationKey == _origin.representationKey) {
          _origin = fresh;
          refreshAttempts++;
          continue;
        }
      }
      final status = response.statusCode;
      await response.drain<void>();
      throw HttpException('Audio stream request failed with HTTP $status.');
    }
  }

  void _setRequestHeaders(HttpClientRequest request) {
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    request.headers.set(HttpHeaders.acceptHeader, '*/*');
    _origin.headers.forEach((key, value) => request.headers.set(key, value));
  }

  bool _isExpiredStatus(int status) =>
      status == HttpStatus.unauthorized ||
      status == HttpStatus.forbidden ||
      status == HttpStatus.gone;

  StreamAudioResponse _wholeResponse(_PreparedAudioResponse prepared) {
    final length = prepared.totalLength ?? _expectedLength;
    return StreamAudioResponse(
      rangeRequestsSupported: false,
      sourceLength: length,
      contentLength: length,
      offset: null,
      contentType: prepared.contentType,
      stream: _consumeWholeResponse(prepared),
    );
  }

  Stream<List<int>> _consumeWholeResponse(_PreparedAudioResponse prepared) =>
      _consumeWholeResponseSlice(prepared, sliceStart: 0, sliceEnd: null);

  Stream<List<int>> _consumeWholeResponseSlice(
    _PreparedAudioResponse prepared, {
    required int sliceStart,
    required int? sliceEnd,
    bool storeLockHeld = false,
  }) async* {
    var offset = 0;
    var total = prepared.totalLength ?? _expectedLength;
    final iterator = StreamIterator<List<int>>(prepared.response);
    try {
      while (await iterator.moveNext()) {
        final chunk = iterator.current;
        if (chunk.isEmpty) continue;
        await _store.writeBytes(
          offset,
          chunk,
          totalLength: total,
          contentType: prepared.contentType,
          etag: prepared.etag,
          lastModified: prepared.lastModified,
          storeLockHeld: storeLockHeld,
        );
        final chunkStart = offset;
        offset += chunk.length;
        total ??= await _store.totalLength();
        await _notifyIfComplete(total);

        final overlapStart = math.max(sliceStart, chunkStart);
        final overlapEnd = sliceEnd == null
            ? offset
            : math.min(sliceEnd, offset);
        if (overlapEnd > overlapStart) {
          yield chunk.sublist(
            overlapStart - chunkStart,
            overlapEnd - chunkStart,
          );
        }
        if (sliceEnd != null && offset >= sliceEnd) break;
      }
      if (sliceEnd == null && total != null && offset != total) {
        throw FormatException(
          'Origin body ended at $offset bytes; expected $total.',
        );
      }
      if (sliceEnd == null && total == null && offset > 0) {
        await _store.updateTotalLength(offset);
        total = offset;
        await _notifyIfComplete(total);
      }
      if (sliceEnd != null && offset < sliceEnd) {
        throw FormatException(
          'Origin body ended at $offset bytes before requested end $sliceEnd.',
        );
      }
    } finally {
      await iterator.cancel();
    }
  }

  Future<void> _notifyIfComplete(int? length) async {
    if (_completionNotified || length == null || _onComplete == null) return;
    if (await _store.isComplete(length)) {
      _completionNotified = true;
      await _onComplete(audioFile);
    }
  }

  int? _coveredEndAt(List<_ByteRange> ranges, int offset) {
    for (final range in ranges) {
      if (range.start <= offset && range.end > offset) return range.end;
      if (range.start > offset) break;
    }
    return null;
  }
}

/// Persistent sparse-byte index for one audio representation.
class PartialAudioCacheStore {
  PartialAudioCacheStore(this.audioFile)
    : _metadataFile = File('${audioFile.path}.ranges.json');

  final File audioFile;
  final File _metadataFile;
  static final Map<String, Future<void>> _locks = <String, Future<void>>{};
  static const int _metadataVersion = 1;

  Future<_PartialCacheMetadata> _read({
    required int? expectedLength,
    required String fallbackContentType,
  }) async {
    _PartialCacheMetadata? loaded;
    try {
      if (await _metadataFile.exists()) {
        final json = jsonDecode(await _metadataFile.readAsString());
        if (json is Map<String, dynamic> &&
            json['version'] == _metadataVersion) {
          loaded = _PartialCacheMetadata.fromJson(json);
        }
      }
    } catch (_) {
      // Corrupt metadata must never make sparse holes look like audio.
    }
    loaded ??= _PartialCacheMetadata.empty(
      totalLength: expectedLength,
      contentType: fallbackContentType,
    );
    if (loaded.totalLength == null && expectedLength != null) {
      loaded = loaded.copyWith(totalLength: expectedLength);
    }
    if (loaded.contentType.isEmpty && fallbackContentType.isNotEmpty) {
      loaded = loaded.copyWith(contentType: fallbackContentType);
    }
    return loaded;
  }

  Future<int?> totalLength() async {
    try {
      if (!await _metadataFile.exists()) return null;
      final json = jsonDecode(await _metadataFile.readAsString());
      if (json is Map<String, dynamic>) {
        return (json['totalLength'] as num?)?.toInt();
      }
    } catch (_) {}
    return null;
  }

  Future<bool> isComplete(int totalLength) async {
    if (totalLength <= 0 || !await audioFile.exists()) return false;
    final meta = await _read(
      expectedLength: totalLength,
      fallbackContentType: '',
    );
    return meta.totalLength == totalLength && meta.covers(0, totalLength);
  }

  /// Returns the end of the contiguous cached range containing [offset].
  /// The result is capped by the physical file length and optional [limit].
  Future<int?> cachedEndFrom(int offset, {int? limit}) async {
    if (offset < 0 || !await audioFile.exists()) return null;
    final fileLength = await audioFile.length();
    if (offset >= fileLength || (limit != null && limit <= offset)) {
      return null;
    }
    final meta = await _read(expectedLength: null, fallbackContentType: '');
    for (final range in meta.ranges) {
      if (range.start <= offset && range.end > offset) {
        var end = math.min(range.end, fileLength);
        if (limit != null) end = math.min(end, limit);
        return end > offset ? end : null;
      }
      if (range.start > offset) break;
    }
    return null;
  }

  /// Returns persisted cache facts without exposing signed stream URLs.
  Future<PartialAudioCacheSnapshot?> snapshot() async {
    if (!await audioFile.exists() || !await _metadataFile.exists()) {
      return null;
    }
    final fileLength = await audioFile.length();
    if (fileLength <= 0) return null;
    final meta = await _read(expectedLength: null, fallbackContentType: '');
    var cachedBytes = 0;
    for (final range in meta.ranges) {
      if (range.start >= fileLength) continue;
      final end = math.min(range.end, fileLength);
      if (end > range.start) cachedBytes += end - range.start;
    }
    if (cachedBytes <= 0) return null;
    return PartialAudioCacheSnapshot(
      totalLength: meta.totalLength,
      contentType: meta.contentType,
      cachedBytes: cachedBytes,
      lastAccessMs: meta.lastAccessMs,
    );
  }

  Stream<List<int>> readStream(int start, int? end) =>
      audioFile.openRead(start, end);

  Future<void> writeBytes(
    int offset,
    List<int> bytes, {
    int? totalLength,
    String? contentType,
    String? etag,
    String? lastModified,
    bool storeLockHeld = false,
  }) async {
    if (bytes.isEmpty) return;
    if (offset < 0 ||
        (totalLength != null && offset + bytes.length > totalLength)) {
      throw FormatException(
        'Audio cache write exceeds the declared file bounds.',
      );
    }
    final release = storeLockHeld ? null : await acquireWriteLock();
    try {
      await audioFile.parent.create(recursive: true);
      final handle = await audioFile.open(mode: FileMode.append);
      try {
        await handle.setPosition(offset);
        await handle.writeFrom(bytes);
        await handle.flush();
      } finally {
        await handle.close();
      }
      final meta = await _read(
        expectedLength: totalLength,
        fallbackContentType: contentType ?? '',
      );
      await _writeMetadata(
        meta.copyWith(
          totalLength: totalLength ?? meta.totalLength,
          contentType: contentType ?? meta.contentType,
          etag: etag ?? meta.etag,
          lastModified: lastModified ?? meta.lastModified,
          ranges: _mergeRanges(
            meta.ranges,
            _ByteRange(offset, offset + bytes.length),
          ),
          lastAccessMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    } finally {
      release?.call();
    }
  }

  Future<void> updateTotalLength(int totalLength) async {
    if (totalLength <= 0) return;
    final release = await acquireWriteLock();
    try {
      final meta = await _read(expectedLength: null, fallbackContentType: '');
      await _writeMetadata(meta.copyWith(totalLength: totalLength));
    } finally {
      release();
    }
  }

  Future<void> updateOrigin({
    required String originFingerprint,
    required int? totalLength,
    required String contentType,
    required String? etag,
    required String? lastModified,
    required bool rangeSupported,
    bool storeLockHeld = false,
  }) async {
    final release = storeLockHeld ? null : await acquireWriteLock();
    try {
      var meta = await _read(
        expectedLength: totalLength,
        fallbackContentType: contentType,
      );
      final oldValidator = meta.etag ?? meta.lastModified;
      final newValidator = etag ?? lastModified;
      final uriChanged =
          meta.originFingerprint != null &&
          meta.originFingerprint != originFingerprint;
      final validatorsMatch =
          oldValidator != null &&
          newValidator != null &&
          oldValidator == newValidator;
      final validatorChanged =
          oldValidator != null &&
          newValidator != null &&
          oldValidator != newValidator;
      final representationChanged =
          validatorChanged || (uriChanged && !validatorsMatch);
      final lengthChanged =
          meta.totalLength != null &&
          totalLength != null &&
          meta.totalLength != totalLength;
      final alreadyComplete =
          meta.totalLength != null && meta.covers(0, meta.totalLength!);

      if ((representationChanged || lengthChanged) && !alreadyComplete) {
        if (await audioFile.exists()) await audioFile.delete();
        meta = _PartialCacheMetadata.empty(
          totalLength: null,
          contentType: contentType,
        );
      }

      await _writeMetadata(
        meta.copyWith(
          originFingerprint: originFingerprint,
          totalLength: totalLength ?? meta.totalLength,
          contentType: contentType,
          etag: etag ?? meta.etag,
          lastModified: lastModified ?? meta.lastModified,
          rangeSupported: rangeSupported,
          lastAccessMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    } finally {
      release?.call();
    }
  }

  /// Registers a file produced by an explicit, verified whole-file download.
  Future<void> markComplete({
    required int totalLength,
    required String contentType,
  }) async {
    if (totalLength <= 0 || !await audioFile.exists()) return;
    if (await audioFile.length() != totalLength) {
      throw FormatException(
        'Completed audio file length does not match metadata.',
      );
    }
    final release = await acquireWriteLock();
    try {
      final meta =
          _PartialCacheMetadata.empty(
            totalLength: totalLength,
            contentType: contentType,
          ).copyWith(
            ranges: <_ByteRange>[_ByteRange(0, totalLength)],
            rangeSupported: false,
          );
      await _writeMetadata(meta);
    } finally {
      release();
    }
  }

  Future<int> cachedByteCount() async {
    final meta = await _read(expectedLength: null, fallbackContentType: '');
    return meta.ranges.fold<int>(0, (sum, range) => sum + range.length);
  }

  Future<DateTime> lastAccess() async {
    final meta = await _read(expectedLength: null, fallbackContentType: '');
    return DateTime.fromMillisecondsSinceEpoch(meta.lastAccessMs);
  }

  Future<void> touch() async {
    if (!await audioFile.exists()) return;
    try {
      await audioFile.setLastModified(DateTime.now());
    } catch (_) {}
  }

  Future<void> delete() async {
    final release = await acquireWriteLock();
    try {
      if (await audioFile.exists()) await audioFile.delete();
      if (await _metadataFile.exists()) await _metadataFile.delete();
    } finally {
      release();
    }
  }

  /// Serializes range fills only for one representation; it is not held for
  /// normal file reads or for unrelated tracks.
  Future<void Function()> acquireWriteLock() async {
    final key = audioFile.absolute.path;
    final previous = _locks[key] ?? Future<void>.value();
    final gate = Completer<void>();
    _locks[key] = gate.future;
    await previous;
    var released = false;
    return () {
      if (released) return;
      released = true;
      gate.complete();
      if (identical(_locks[key], gate.future)) _locks.remove(key);
    };
  }

  Future<void> _writeMetadata(_PartialCacheMetadata metadata) async {
    await _metadataFile.parent.create(recursive: true);
    final temporary = File('${_metadataFile.path}.tmp');
    await temporary.writeAsString(
      jsonEncode(metadata.toJson(_metadataVersion)),
    );
    if (await _metadataFile.exists()) await _metadataFile.delete();
    await temporary.rename(_metadataFile.path);
  }

  static Future<int> cacheBytesFor(File audioFile) =>
      PartialAudioCacheStore(audioFile).cachedByteCount();

  static Future<DateTime> cacheLastAccessFor(File audioFile) async {
    final metadata = File('${audioFile.path}.ranges.json');
    DateTime? metadataAccess;
    try {
      final json = jsonDecode(await metadata.readAsString());
      if (json is Map<String, dynamic>) {
        final millis = (json['lastAccessMs'] as num?)?.toInt();
        if (millis != null) {
          metadataAccess = DateTime.fromMillisecondsSinceEpoch(millis);
        }
      }
    } catch (_) {}
    try {
      final modified = (await audioFile.stat()).modified;
      if (metadataAccess == null || modified.isAfter(metadataAccess)) {
        return modified;
      }
      return metadataAccess;
    } catch (_) {
      return metadataAccess ?? DateTime.fromMillisecondsSinceEpoch(0);
    }
  }

  static Future<void> deleteCacheFor(File audioFile) =>
      PartialAudioCacheStore(audioFile).delete();
}

class _PreparedAudioResponse {
  _PreparedAudioResponse.range(
    this.response, {
    required this.start,
    required this.end,
    required this.totalLength,
    required this.contentType,
  }) : isRange = true,
       isWholeResponse = false;

  _PreparedAudioResponse.whole(
    this.response, {
    required this.totalLength,
    required this.contentType,
  }) : start = 0,
       end =
           totalLength ??
           (response.contentLength > 0 ? response.contentLength : null),
       isRange = false,
       isWholeResponse = true;

  final HttpClientResponse response;
  final int start;
  final int? end;
  final int? totalLength;
  final String contentType;
  final bool isRange;
  final bool isWholeResponse;

  String? get etag => response.headers.value(HttpHeaders.etagHeader);
  String? get lastModified =>
      response.headers.value(HttpHeaders.lastModifiedHeader);

  Future<void> close() async {
    try {
      await response.drain<void>();
    } catch (_) {}
  }
}

class _ParsedContentRange {
  const _ParsedContentRange(this.start, this.end, this.total);
  final int start;
  final int end; // exclusive
  final int? total;

  static _ParsedContentRange? parse(String? value) {
    if (value == null) return null;
    final match = RegExp(
      r'^bytes\s+(\d+)-(\d+)/(\d+|\*)$',
      caseSensitive: false,
    ).firstMatch(value.trim());
    if (match == null) return null;
    final start = int.tryParse(match.group(1)!);
    final inclusiveEnd = int.tryParse(match.group(2)!);
    final total = match.group(3) == '*' ? null : int.tryParse(match.group(3)!);
    if (start == null || inclusiveEnd == null || inclusiveEnd < start) {
      return null;
    }
    if (total != null && inclusiveEnd >= total) return null;
    return _ParsedContentRange(start, inclusiveEnd + 1, total);
  }
}

class _ByteRange {
  const _ByteRange(this.start, this.end);
  final int start;
  final int end; // exclusive
  int get length => end - start;
}

class _PartialCacheMetadata {
  const _PartialCacheMetadata({
    required this.totalLength,
    required this.contentType,
    required this.etag,
    required this.lastModified,
    required this.originFingerprint,
    required this.rangeSupported,
    required this.ranges,
    required this.lastAccessMs,
  });

  factory _PartialCacheMetadata.empty({
    required int? totalLength,
    required String contentType,
  }) => _PartialCacheMetadata(
    totalLength: totalLength,
    contentType: contentType,
    etag: null,
    lastModified: null,
    originFingerprint: null,
    rangeSupported: null,
    ranges: const <_ByteRange>[],
    lastAccessMs: DateTime.now().millisecondsSinceEpoch,
  );

  factory _PartialCacheMetadata.fromJson(Map<String, dynamic> json) {
    final rawRanges = json['ranges'];
    final ranges = <_ByteRange>[];
    if (rawRanges is List) {
      for (final raw in rawRanges) {
        if (raw is List && raw.length == 2 && raw[0] is num && raw[1] is num) {
          final start = (raw[0] as num).toInt();
          final end = (raw[1] as num).toInt();
          if (start >= 0 && end > start) ranges.add(_ByteRange(start, end));
        }
      }
    }
    return _PartialCacheMetadata(
      totalLength: (json['totalLength'] as num?)?.toInt(),
      contentType: json['contentType']?.toString() ?? '',
      etag: json['etag']?.toString(),
      lastModified: json['lastModified']?.toString(),
      originFingerprint: json['originFingerprint']?.toString(),
      rangeSupported: json['rangeSupported'] as bool?,
      ranges: _mergeAllRanges(ranges),
      lastAccessMs:
          (json['lastAccessMs'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
    );
  }

  final int? totalLength;
  final String contentType;
  final String? etag;
  final String? lastModified;
  final String? originFingerprint;
  final bool? rangeSupported;
  final List<_ByteRange> ranges;
  final int lastAccessMs;

  bool covers(int start, int end) {
    if (end <= start) return true;
    var cursor = start;
    for (final range in ranges) {
      if (range.end <= cursor) continue;
      if (range.start > cursor) return false;
      cursor = math.max(cursor, range.end);
      if (cursor >= end) return true;
    }
    return false;
  }

  Map<String, dynamic> toJson(int version) => <String, dynamic>{
    'version': version,
    'totalLength': totalLength,
    'contentType': contentType,
    'etag': etag,
    'lastModified': lastModified,
    // A hash only; the original signed URL is never persisted.
    'originFingerprint': originFingerprint,
    'rangeSupported': rangeSupported,
    'ranges': ranges.map((range) => <int>[range.start, range.end]).toList(),
    'lastAccessMs': lastAccessMs,
  };

  _PartialCacheMetadata copyWith({
    int? totalLength,
    String? contentType,
    String? etag,
    String? lastModified,
    String? originFingerprint,
    bool? rangeSupported,
    List<_ByteRange>? ranges,
    int? lastAccessMs,
  }) => _PartialCacheMetadata(
    totalLength: totalLength ?? this.totalLength,
    contentType: contentType ?? this.contentType,
    etag: etag ?? this.etag,
    lastModified: lastModified ?? this.lastModified,
    originFingerprint: originFingerprint ?? this.originFingerprint,
    rangeSupported: rangeSupported ?? this.rangeSupported,
    ranges: ranges ?? this.ranges,
    lastAccessMs: lastAccessMs ?? this.lastAccessMs,
  );
}

List<_ByteRange> _mergeRanges(List<_ByteRange> existing, _ByteRange added) =>
    _mergeAllRanges(<_ByteRange>[...existing, added]);

List<_ByteRange> _mergeAllRanges(List<_ByteRange> input) {
  if (input.isEmpty) return const <_ByteRange>[];
  final sorted = input.toList()..sort((a, b) => a.start.compareTo(b.start));
  final merged = <_ByteRange>[];
  var current = sorted.first;
  for (final next in sorted.skip(1)) {
    if (next.start <= current.end) {
      current = _ByteRange(current.start, math.max(current.end, next.end));
    } else {
      merged.add(current);
      current = next;
    }
  }
  merged.add(current);
  return merged;
}
