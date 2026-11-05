import 'dart:convert';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:http/http.dart' as http;
import 'lyrics_models.dart';
import 'enhanced_lrc_parser.dart';
import 'background_vocals.dart';
import 'instrumental_gaps.dart';

/// SimpMusic provider - community database keyed directly on YouTube Video ID
/// Endpoint: https://api-lyrics.simpmusic.org/v1/{videoId}
class SimpMusicProvider implements LyricsProvider {
  @override
  String get name => 'SimpMusic';

  static const _baseUrl = 'https://api-lyrics.simpmusic.org/v1/';
  static const _durationToleranceSeconds = 10;
  static const _timeout = Duration(seconds: 8);
  static final http.Client _client = http.Client();

  @override
  Future<LyricResult?> search(LyricsSearchInfo info) async {
    if (info.videoId.trim().isEmpty) return null;

    try {
      final url = Uri.parse('$_baseUrl${info.videoId.trim()}');
      final response = await _client.get(
        url,
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Accept': 'application/json',
        },
      ).timeout(_timeout);

      if (response.statusCode != 200) {
        return null;
      }

      final json = jsonDecode(response.body);
      if (json is! Map || json['success'] != true) {
        return null;
      }

      final data = json['data'];
      if (data is! List || data.isEmpty) return null;

      // Find closest duration candidate
      final targetSeconds = info.durationSeconds;
      Map<String, dynamic>? bestTrack;
      int minDiff = 999999;

      for (final item in data) {
        if (item is! Map) continue;
        final dur = item['duration'];
        final durSec = dur is num ? dur.toInt() : null;

        if (targetSeconds <= 0 || durSec == null) {
          bestTrack ??= Map<String, dynamic>.from(item);
          continue;
        }

        final diff = (durSec - targetSeconds).abs();
        if (diff <= _durationToleranceSeconds && diff < minDiff) {
          minDiff = diff;
          bestTrack = Map<String, dynamic>.from(item);
        }
      }

      bestTrack ??= Map<String, dynamic>.from(data.first as Map);

      // 1. Try word-synced rich sync lyrics first
      final richSync = bestTrack['richSyncLyrics'] as String?;
      if (richSync != null && richSync.trim().isNotEmpty) {
        final parsed = EnhancedLrcParser.parse(richSync);
        if (parsed.isNotEmpty) {
          final withBg = parsed.withBackgroundVocals();
          if (kDebugMode) {
            print('SimpMusic: Found word-synced lyrics for ${info.videoId}');
          }
          return LyricResult(
            title: info.title,
            artists: [info.artist],
            lines: withBg,
            source: name,
          );
        }
      }

      // 2. Fall back to standard synced lyrics
      final synced = bestTrack['syncedLyrics'] as String?;
      if (synced != null && synced.trim().isNotEmpty) {
        final lines = _parseStandardLrc(synced);
        if (lines.isNotEmpty) {
          final processed = lines.withBackgroundVocals().withInstrumentalGaps();
          if (kDebugMode) {
            print('SimpMusic: Found line-synced lyrics for ${info.videoId}');
          }
          return LyricResult(
            title: info.title,
            artists: [info.artist],
            lines: processed,
            source: name,
          );
        }
      }

      // 3. Fall back to plain lyrics
      final plain = bestTrack['plainLyrics'] as String?;
      if (plain != null && plain.trim().isNotEmpty) {
        return LyricResult(
          title: info.title,
          artists: [info.artist],
          lyrics: plain.trim(),
          source: name,
        );
      }

      return null;
    } catch (e) {
      if (kDebugMode) {
        print('SimpMusicProvider error for ${info.videoId}: $e');
      }
      return null;
    }
  }

  static List<LyricLine> _parseStandardLrc(String lrc) {
    final rawLines = lrc.split('\n');
    final result = <LyricLine>[];
    final regex = RegExp(r'^\[(\d{1,3}):(\d{2})[.:](\d{2,3})\](.*)$');

    for (final raw in rawLines) {
      final line = raw.trim();
      final match = regex.firstMatch(line);
      if (match != null) {
        final m = int.parse(match.group(1)!);
        final s = int.parse(match.group(2)!);
        final frac = match.group(3)!;
        final fracMs = frac.length == 3 ? int.parse(frac) : int.parse(frac) * 10;
        final text = EnhancedLrcParser.decodeEntities(match.group(4) ?? '').trim();
        result.add(LyricLine(
          timeInMs: m * 60000 + s * 1000 + fracMs,
          text: text,
        ));
      }
    }
    result.sort((a, b) => a.timeInMs.compareTo(b.timeInMs));
    return result;
  }
}
