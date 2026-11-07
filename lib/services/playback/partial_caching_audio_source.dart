import 'dart:async';
import 'dart:io';
import 'package:just_audio/just_audio.dart';
import 'partial_audio_cache_store.dart';

class PartialCachingAudioSource extends StreamAudioSource {
  PartialCachingAudioSource({required this.uri, required this.cacheFile, this.headers,
    this.expectedLength, this.contentType = 'audio/mpeg', dynamic tag})
      : store = PartialAudioCacheStore(cacheFile), super(tag: tag);
  final Uri uri;
  final File cacheFile;
  final Map<String, String>? headers;
  final int? expectedLength;
  final String contentType;
  final PartialAudioCacheStore store;

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final rangeStart = start ?? 0;
    final requestedEnd = end ?? (rangeStart + 256 * 1024);
    final rangeEnd = expectedLength == null
        ? requestedEnd
        : (requestedEnd < expectedLength! ? requestedEnd : expectedLength!);
    if (rangeStart < 0 || (rangeEnd != null && rangeEnd <= rangeStart)) throw RangeError('Invalid audio byte range');
    await store.load();
    if (rangeEnd != null && await cacheFile.exists() && store.contains(rangeStart, rangeEnd)) {
      return StreamAudioResponse(sourceLength: expectedLength, contentLength: rangeEnd - rangeStart,
        offset: rangeStart, contentType: contentType, stream: await store.readRange(rangeStart, rangeEnd));
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.getUrl(uri);
      headers?.forEach((key, value) => request.headers.set(key, value));
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      if (rangeEnd != null) request.headers.set(HttpHeaders.rangeHeader, 'bytes=$rangeStart-${rangeEnd - 1}');
      final response = await request.close();
      if (response.statusCode != HttpStatus.partialContent && response.statusCode != HttpStatus.ok) {
        throw HttpException('Audio range request failed: HTTP ${response.statusCode}', uri: uri);
      }
      final partial = response.statusCode == HttpStatus.partialContent;
      final actualStart = partial ? rangeStart : 0;
      final sourceLength = _totalLength(response.headers.value(HttpHeaders.contentRangeHeader)) ??
          expectedLength ?? (response.contentLength >= 0 ? response.contentLength : null);
      final mime = response.headers.contentType?.mimeType ?? contentType;
      final skip = rangeStart - actualStart;
      final wanted = rangeEnd == null ? null : rangeEnd - rangeStart;
      final controller = StreamController<List<int>>();
      unawaited(() async {
        var skipped = 0, written = 0;
        final chunks = <List<int>>[];
        try {
          await for (final chunk in response) {
            var data = chunk;
            if (skipped < skip) {
              final drop = (skip - skipped).clamp(0, data.length);
              data = data.sublist(drop); skipped += drop;
            }
            if (data.isEmpty) continue;
            if (wanted != null) {
              final remaining = wanted - written;
              if (remaining <= 0) break;
              if (data.length > remaining) data = data.sublist(0, remaining);
            }
            chunks.add(data); controller.add(data); written += data.length;
          }
          if (wanted != null && written != wanted) throw HttpException('Audio range truncated ($written/$wanted)');
          await store.writeRange(rangeStart, Stream<List<int>>.fromIterable(chunks));
          await controller.close();
        } catch (error, stack) {
          controller.addError(error, stack); await controller.close();
        } finally { client.close(force: true); }
      }());
      return StreamAudioResponse(sourceLength: sourceLength, contentLength: wanted,
        offset: rangeStart, contentType: mime, stream: controller.stream);
    } catch (_) { client.close(force: true); rethrow; }
  }

  int? _totalLength(String? value) {
    if (value == null) return null;
    final match = RegExp(r'^bytes\s+\d+-\d+/(\d+|\*)$', caseSensitive: false).firstMatch(value.trim());
    return int.tryParse(match?.group(1) ?? '');
  }
}
