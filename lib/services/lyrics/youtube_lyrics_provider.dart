import 'dart:convert';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:http/http.dart' as http;
import '../ytmusic_api_service.dart';
import 'lyrics_models.dart';
import 'instrumental_gaps.dart';

/// YouTube Music official lyrics & YouTube captions provider
class YouTubeLyricsProvider implements LyricsProvider {
  @override
  String get name => 'YouTube Music';

  final InnerTubeService _innerTube;
  static const _requestTimeout = Duration(seconds: 8);
  static final http.Client _client = http.Client();

  YouTubeLyricsProvider([InnerTubeService? innerTube])
    : _innerTube = innerTube ?? InnerTubeService();

  @override
  Future<LyricResult?> search(LyricsSearchInfo info) async {
    try {
      if (info.videoId.isEmpty) return null;

      // 1. Try YouTube Music official lyrics endpoint first
      final officialLyrics = await _innerTube.getLyrics(info.videoId);
      if (officialLyrics != null && officialLyrics.trim().isNotEmpty) {
        if (kDebugMode) {
          print(
            'YouTubeLyricsProvider: Found official lyrics for ${info.videoId}',
          );
        }
        return LyricResult(
          title: info.title,
          artists: [info.artist],
          lyrics: officialLyrics.trim(),
          source: name,
        );
      }

      // 2. Fallback to YouTube timed subtitles / captions if available
      final captionResult = await _fetchYouTubeCaptions(info.videoId, info);
      if (captionResult != null) {
        return captionResult;
      }

      return null;
    } catch (e) {
      if (kDebugMode) {
        print('YouTubeLyricsProvider error: $e');
      }
      return null;
    }
  }

  /// Fetch YouTube video timed captions (json3 format)
  Future<LyricResult?> _fetchYouTubeCaptions(
    String videoId,
    LyricsSearchInfo info,
  ) async {
    try {
      final uri = Uri.parse(
        'https://www.youtube.com/api/timedtext?v=$videoId&lang=en&fmt=json3',
      );
      final response = await _client
          .get(
            uri,
            headers: {
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
              'Accept': 'application/json',
            },
          )
          .timeout(_requestTimeout);

      if (response.statusCode != 200) return null;

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final events = data['events'] as List?;
      if (events == null || events.isEmpty) return null;

      final lines = <LyricLine>[];
      for (final event in events) {
        final tStartMs = (event['tStartMs'] as num?)?.toInt() ?? 0;
        final dDurationMs = (event['dDurationMs'] as num?)?.toInt();
        final segs = event['segs'] as List?;
        if (segs == null || segs.isEmpty) continue;

        final lineText = segs
            .map((s) => s['utf8'] as String? ?? '')
            .join('')
            .replaceAll('\n', ' ')
            .trim();

        if (lineText.isEmpty) continue;

        lines.add(
          LyricLine(
            timeInMs: tStartMs,
            durationMs: dDurationMs,
            text: lineText,
          ),
        );
      }

      if (lines.isEmpty) return null;

      return LyricResult(
        title: info.title,
        artists: [info.artist],
        lines: lines.withInstrumentalGaps(),
        source: 'YouTube Subtitle',
      );
    } catch (_) {
      return null;
    }
  }
}
