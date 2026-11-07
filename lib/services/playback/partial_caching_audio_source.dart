import 'dart:async';
import 'dart:io';

import 'package:just_audio/just_audio.dart';

import 'partial_audio_cache_store.dart';

/// Fetches only decoder-requested ranges and persists complete ranges.
/// It never starts a whole-file GET as a side effect of source creation.
class PartialCachingAudioSource extends StreamAudioSource {
  PartialCachingAudioSource({
    required this.uri,
    required this.cacheFile,
    this.headers,
    this.expectedLength,
    this.contentType = 'audio/mpeg',
    this.onCacheUpdated,
    dynamic tag,
  })  : store = PartialAudioCacheStore(cacheFile),
        super(tag: tag);

  final Uri uri;
  final File cacheFile;
  final Map<String, String>? headers;
  final int? expectedLength;
  final String contentType;
  final Future<void> Function()? onCacheUpdated;
  final PartialAudioCacheStore store;
  int? _resolvedLength;

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final rangeStart = start ?? 0;
    final knownLength = expectedLength ?? _resolvedLength;
    final requestedEnd = end ?? (rangeStart + 256 * 1024);
    final rangeEnd = knownLength == null
        ? requestedEnd
        : (requestedEnd < knownLength ? requestedEnd : knownLength);
    if (rangeStart < 0 || rangeEnd <= rangeStart) {
      throw RangeError('Invalid audio byte range: $rangeStart-$rangeEnd');
    }

    await store.load();
    // Sparse cache files are separate from cacheFile itself. Never gate this
    // lookup on the existence of the legacy whole-file cache path.
    if (store.contains(rangeStart, rangeEnd)) {
      return StreamAudioResponse(
        sourceLength: expectedLength,
        contentLength: rangeEnd - rangeStart,
        offset: rangeStart,
        contentType: contentType,
        stream: await store.readRange(rangeStart, rangeEnd),
      );
    }

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.getUrl(uri);
      headers?.forEach((key, value) => request.headers.set(key, value));
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$rangeStart-${rangeEnd - 1}');
      final response = await request.close();
      if (response.statusCode != HttpStatus.partialContent &&
          response.statusCode != HttpStatus.ok) {
        throw HttpException('Audio range request failed: HTTP ${response.statusCode}', uri: uri);
      }

      final isPartial = response.statusCode == HttpStatus.partialContent;
      final actualStart = isPartial ? rangeStart : 0;
      final sourceLength = _totalLength(response.headers.value(HttpHeaders.contentRangeHeader)) ??
          expectedLength ?? (response.contentLength >= 0 ? response.contentLength : null);
      if (expectedLength == null && sourceLength != null) _resolvedLength = sourceLength;
      final mime = response.headers.contentType?.mimeType ?? contentType;
      final skipBytes = rangeStart - actualStart;
      final requestedLength = rangeEnd - rangeStart;
      final responseLength = response.contentLength >= 0 ? response.contentLength : requestedLength;
      final wantedLength = isPartial && responseLength < requestedLength
          ? responseLength
          : requestedLength;
      if (skipBytes < 0 || (sourceLength != null && rangeStart >= sourceLength)) {
        client.close(force: true);
        throw HttpException('Server returned an invalid byte range', uri: uri);
      }

      final controller = StreamController<List<int>>();
      unawaited(() async {
        var skipped = 0;
        var written = 0;
        final chunks = <List<int>>[];
        try {
          await for (final chunk in response) {
            var data = chunk;
            if (skipped < skipBytes) {
              final drop = (skipBytes - skipped).clamp(0, data.length);
              data = data.sublist(drop);
              skipped += drop;
            }
            if (data.isEmpty) continue;
            final remaining = wantedLength - written;
            if (remaining <= 0) break;
            if (data.length > remaining) data = data.sublist(0, remaining);
            chunks.add(data);
            controller.add(data);
            written += data.length;
          }
          if (written != wantedLength) {
            throw HttpException('Audio range truncated ($written/$wantedLength bytes)', uri: uri);
          }
          // A cache write failure must not interrupt otherwise successful audio playback.
          try {
            await store.writeRange(rangeStart, Stream<List<int>>.fromIterable(chunks));
            final callback = onCacheUpdated;
            if (callback != null) unawaited(callback().catchError((Object _) {}));
          } catch (_) {}
          await controller.close();
        } catch (error, stack) {
          controller.addError(error, stack);
          await controller.close();
        } finally {
          client.close(force: true);
        }
      }());

      return StreamAudioResponse(
        sourceLength: sourceLength,
        contentLength: wantedLength,
        offset: rangeStart,
        contentType: mime,
        stream: controller.stream,
      );
    } catch (_) {
      client.close(force: true);
      rethrow;
    }
  }

  int? _totalLength(String? value) {
    if (value == null) return null;
    final match = RegExp(r'^bytes\s+(\d+)-(\d+)/(\d+|\*)$', caseSensitive: false)
        .firstMatch(value.trim());
    if (match == null) return null;
    return int.tryParse(match.group(3) ?? '');
  }
}
