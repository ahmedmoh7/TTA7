import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:inzx/services/playback/partial_audio_cache.dart';

class _RangeTestOrigin {
  _RangeTestOrigin(
    this.bytes, {
    required this.supportsRange,
    this.statusCode,
    this.omitTotalInRange = false,
  }) {
    unawaited(_start());
  }

  final List<int> bytes;
  final bool supportsRange;
  final int? statusCode;
  final bool omitTotalInRange;
  final requests = <String?>[];
  late final HttpServer server;
  final Completer<void> ready = Completer<void>();
  bool _closed = false;

  Future<void> _start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) => unawaited(_handle(request)));
    ready.complete();
  }

  Future<Uri> get uri async {
    await ready.future;
    return Uri.parse('http://${server.address.address}:${server.port}/audio');
  }

  Future<void> _handle(HttpRequest request) async {
    final range = request.headers.value(HttpHeaders.rangeHeader);
    requests.add(range);
    request.response.headers.contentType = ContentType('audio', 'mpeg');
    request.response.headers.set(HttpHeaders.etagHeader, '"stable-v1"');
    if (statusCode != null) {
      request.response.statusCode = statusCode!;
      await request.response.close();
      return;
    }

    if (supportsRange && range != null) {
      final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
      if (match == null) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }
      final start = int.parse(match.group(1)!);
      final requestedEnd = match.group(2)!.isEmpty
          ? bytes.length - 1
          : int.parse(match.group(2)!);
      if (start >= bytes.length) {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */${bytes.length}',
        );
        await request.response.close();
        return;
      }
      final end = requestedEnd.clamp(start, bytes.length - 1);
      final body = bytes.sublist(start, end + 1);
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/${omitTotalInRange ? '*' : bytes.length}',
      );
      request.response.contentLength = body.length;
      request.response.add(body);
      await request.response.close();
      return;
    }

    request.response.statusCode = HttpStatus.ok;
    request.response.contentLength = bytes.length;
    // Deliberately pace a 200 response so a consumer can cancel after receiving
    // its first buffered chunk; the source must not keep downloading the rest.
    const chunkSize = 8192;
    for (var offset = 0; offset < bytes.length; offset += chunkSize) {
      final end = (offset + chunkSize).clamp(0, bytes.length);
      request.response.add(bytes.sublist(offset, end));
      try {
        await request.response.flush();
      } on SocketException {
        break;
      } catch (_) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 8));
    }
    try {
      await request.response.close();
    } catch (_) {}
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await ready.future;
    await server.close(force: true);
  }
}

void main() {
  late Directory tempDir;
  final origins = <_RangeTestOrigin>[];

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'partial-audio-cache-test-',
    );
  });

  tearDown(() async {
    for (final origin in origins) {
      await origin.close();
    }
    origins.clear();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  PartialAudioOrigin makeOrigin(
    Uri uri,
    String representationKey,
    int? length,
  ) => PartialAudioOrigin(
    uri: uri,
    representationKey: representationKey,
    contentType: 'audio/mpeg',
    contentLength: length,
  );

  test(
    'reuses cached ranges and requests only gaps, then plays fully offline',
    () async {
      final bytes = List<int>.generate(16 * 1024, (i) => (i * 31) & 0xff);
      final server = _RangeTestOrigin(bytes, supportsRange: true);
      origins.add(server);
      final key = 'track-a-provider-a-128k-v1';
      final cacheFile = File('${tempDir.path}/track-a_$key.audio');
      final origin = makeOrigin(await server.uri, key, bytes.length);
      final source = PartialCachingAudioSource(
        origin: origin,
        audioFile: cacheFile,
        expectedLength: bytes.length,
        rangeChunkBytes: 4096,
      );

      final first = await source.request(0, 4096);
      expect(
        await first.stream.fold<List<int>>(
          <int>[],
          (all, part) => all..addAll(part),
        ),
        bytes.sublist(0, 4096),
      );
      expect(server.requests, <String?>['bytes=0-4095']);
      expect(await PartialAudioCacheStore.cacheBytesFor(cacheFile), 4096);

      final replay = await source.request(0, 4096);
      expect(
        await replay.stream.fold<List<int>>(
          <int>[],
          (all, part) => all..addAll(part),
        ),
        bytes.sublist(0, 4096),
      );
      expect(server.requests, <String?>['bytes=0-4095']);

      final missing = await source.request(4096, 8192);
      expect(
        await missing.stream.fold<List<int>>(
          <int>[],
          (all, part) => all..addAll(part),
        ),
        bytes.sublist(4096, 8192),
      );
      expect(server.requests.last, 'bytes=4096-8191');
      expect(server.requests.length, 2);

      final tail = await source.request(8192, bytes.length);
      expect(
        await tail.stream.fold<List<int>>(
          <int>[],
          (all, part) => all..addAll(part),
        ),
        bytes.sublist(8192),
      );
      expect(
        await PartialAudioCacheStore(cacheFile).isComplete(bytes.length),
        isTrue,
      );
      expect(server.requests.length, 4);

      await server.close();
      final offlineSource = PartialCachingAudioSource(
        origin: origin,
        audioFile: cacheFile,
        expectedLength: bytes.length,
        rangeChunkBytes: 4096,
      );
      final offline = await offlineSource.request(0, bytes.length);
      expect(
        await offline.stream.fold<List<int>>(
          <int>[],
          (all, part) => all..addAll(part),
        ),
        bytes,
      );
      expect(server.requests.length, 4);
    },
  );

  test(
    'replays persisted partial ranges offline after creating a new source',
    () async {
      final bytes = List<int>.generate(16 * 1024, (i) => (i * 23) & 0xff);
      final server = _RangeTestOrigin(bytes, supportsRange: true);
      origins.add(server);
      final key = 'track-offline-restart-v1';
      final cacheFile = File('${tempDir.path}/track-offline_$key.audio');

      final onlineSource = PartialCachingAudioSource(
        origin: makeOrigin(await server.uri, key, bytes.length),
        audioFile: cacheFile,
        expectedLength: bytes.length,
        rangeChunkBytes: 4096,
      );
      final onlineResponse = await onlineSource.request(0, 4096);
      expect(
        await onlineResponse.stream.fold<List<int>>(
          <int>[],
          (all, part) => all..addAll(part),
        ),
        bytes.sublist(0, 4096),
      );
      expect(await PartialAudioCacheStore.cacheBytesFor(cacheFile), 4096);

      await server.close();
      final offlineSource = PartialCachingAudioSource(
        origin: PartialAudioOrigin(
          uri: Uri.parse('http://127.0.0.1:1/never-contact'),
          representationKey: key,
          contentType: 'audio/mpeg',
          contentLength: bytes.length,
        ),
        audioFile: cacheFile,
        expectedLength: bytes.length,
        rangeChunkBytes: 4096,
        offlineOnly: true,
      );

      final offlineResponse = await offlineSource.request(0, 4096);
      expect(
        await offlineResponse.stream.fold<List<int>>(
          <int>[],
          (all, part) => all..addAll(part),
        ),
        bytes.sublist(0, 4096),
      );
      await expectLater(
        offlineSource.request(4096, 8192),
        throwsA(isA<HttpException>()),
      );
      expect(server.requests, <String?>['bytes=0-4095']);
    },
  );

  test(
    'a 200/no-Range origin is streamed and cached progressively, not eagerly',
    () async {
      final bytes = List<int>.generate(5 * 1024 * 1024, (i) => i & 0xff);
      final server = _RangeTestOrigin(bytes, supportsRange: false);
      origins.add(server);
      final key = 'track-b-provider-b-320k-v1';
      final cacheFile = File('${tempDir.path}/track-b_$key.audio');
      final source = PartialCachingAudioSource(
        origin: makeOrigin(await server.uri, key, bytes.length),
        audioFile: cacheFile,
        expectedLength: bytes.length,
        rangeChunkBytes: 4096,
      );

      final response = await source.request(0, null);
      expect(response.rangeRequestsSupported, isFalse);
      final firstChunk = Completer<void>();
      late StreamSubscription<List<int>> subscription;
      subscription = response.stream.listen((chunk) {
        if (!firstChunk.isCompleted) {
          expect(chunk, isNotEmpty);
          firstChunk.complete();
          unawaited(subscription.cancel());
        }
      });
      await firstChunk.future;
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final cachedBytes = await PartialAudioCacheStore.cacheBytesFor(cacheFile);
      expect(cachedBytes, greaterThan(0));
      expect(cachedBytes, lessThan(bytes.length));
      expect(server.requests.length, 1);
      final release = await PartialAudioCacheStore(
        cacheFile,
      ).acquireWriteLock().timeout(const Duration(seconds: 2));
      release();
    },
  );

  test('does not mark a short physical file complete from metadata alone', () async {
    final cacheFile = File('${tempDir.path}/short-cache.audio');
    await cacheFile.writeAsBytes(List<int>.filled(4, 0));
    await File('${cacheFile.path}.ranges.json').writeAsString(
      jsonEncode(<String, dynamic>{
        'version': 1,
        'totalLength': 8,
        'contentType': 'audio/mpeg',
        'etag': null,
        'lastModified': null,
        'originFingerprint': null,
        'rangeSupported': true,
        'ranges': <List<int>>[
          <int>[0, 8],
        ],
        'lastAccessMs': DateTime.now().millisecondsSinceEpoch,
      }),
    );

    expect(
      await PartialAudioCacheStore(cacheFile).isComplete(8),
      isFalse,
    );
  });

  test('out-of-order seeks are written at the correct file offsets', () async {
    final bytes = List<int>.generate(16 * 1024, (i) => (i * 19) & 0xff);
    final server = _RangeTestOrigin(bytes, supportsRange: true);
    origins.add(server);
    final key = 'track-seek-provider-128k-v1';
    final cacheFile = File('${tempDir.path}/track-seek_$key.audio');
    final source = PartialCachingAudioSource(
      origin: makeOrigin(await server.uri, key, bytes.length),
      audioFile: cacheFile,
      expectedLength: bytes.length,
      rangeChunkBytes: 4096,
    );

    for (final (start, end) in <(int, int)>[
      (8192, 12288),
      (0, 4096),
      (4096, 8192),
      (12288, 16384),
    ]) {
      final response = await source.request(start, end);
      expect(
        await response.stream.fold<List<int>>(
          <int>[],
          (all, part) => all..addAll(part),
        ),
        bytes.sublist(start, end),
      );
    }

    expect(await cacheFile.readAsBytes(), bytes);
    expect(
      await PartialAudioCacheStore(cacheFile).isComplete(bytes.length),
      isTrue,
    );
  });

  test(
    'unknown-total 206 falls back before returning an invalid open-ended 206',
    () async {
      final bytes = List<int>.generate(8192, (i) => (i * 13) & 0xff);
      final server = _RangeTestOrigin(
        bytes,
        supportsRange: true,
        omitTotalInRange: true,
      );
      origins.add(server);
      final key = 'track-unknown-length-v1';
      final cacheFile = File('${tempDir.path}/track-unknown_$key.audio');
      final source = PartialCachingAudioSource(
        origin: makeOrigin(await server.uri, key, null),
        audioFile: cacheFile,
        expectedLength: null,
        rangeChunkBytes: 4096,
      );

      final response = await source.request(0, null);
      expect(response.rangeRequestsSupported, isFalse);
      expect(response.offset, isNull);
      expect(response.contentLength, bytes.length);
      expect(
        await response.stream.fold<List<int>>(
          <int>[],
          (all, part) => all..addAll(part),
        ),
        bytes,
      );
      expect(server.requests.length, 2);
      expect(
        await PartialAudioCacheStore(cacheFile).isComplete(bytes.length),
        isTrue,
      );
    },
  );

  test(
    'refreshes an expired signed URL only when the representation key matches',
    () async {
      final bytes = List<int>.generate(8192, (i) => (i * 7) & 0xff);
      final expired = _RangeTestOrigin(
        bytes,
        supportsRange: false,
        statusCode: HttpStatus.forbidden,
      );
      final fresh = _RangeTestOrigin(bytes, supportsRange: true);
      origins.addAll(<_RangeTestOrigin>[expired, fresh]);
      final key = 'track-c-addon-flac-v1';
      final cacheFile = File('${tempDir.path}/track-c_$key.audio');
      final source = PartialCachingAudioSource(
        origin: makeOrigin(await expired.uri, key, bytes.length),
        audioFile: cacheFile,
        expectedLength: bytes.length,
        rangeChunkBytes: 4096,
        refreshOrigin: () async =>
            makeOrigin(await fresh.uri, key, bytes.length),
      );

      final response = await source.request(0, 4096);
      expect(
        await response.stream.fold<List<int>>(
          <int>[],
          (all, part) => all..addAll(part),
        ),
        bytes.sublist(0, 4096),
      );
      expect(expired.requests.length, 1);
      expect(fresh.requests, <String?>['bytes=0-4095']);
    },
  );
}
