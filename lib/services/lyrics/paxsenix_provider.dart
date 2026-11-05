import 'dart:convert';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:http/http.dart' as http;
import 'lyrics_cleaner.dart';
import 'lyrics_models.dart';
import 'ttml_parser.dart';
import 'enhanced_lrc_parser.dart';
import 'background_vocals.dart';
import 'instrumental_gaps.dart';

/// PaxSenix provider - Apple Music catalog proxy with word-synced TTML & Enhanced LRC
/// Proxy: https://lyrics.paxsenix.org
class PaxSenixProvider implements LyricsProvider {
  @override
  String get name => 'PaxSenix';

  static const _proxy = 'https://lyrics.paxsenix.org';
  static const _appleSearch = 'https://amp-api.music.apple.com/v1/catalog/us/search';
  static const _durationToleranceSeconds = 10;
  static const _timeout = Duration(seconds: 10);
  static final http.Client _client = http.Client();

  static String? _cachedToken;
  static DateTime? _tokenFetchedAt;

  @override
  Future<LyricResult?> search(LyricsSearchInfo info) async {
    try {
      final seconds = info.durationSeconds;
      final cleanTitle = LyricsCleaner.cleanTitle(info.title);
      final cleanArtist = LyricsCleaner.cleanArtist(info.artist);

      final queryParts = [cleanTitle, if (cleanArtist.isNotEmpty) cleanArtist];
      final query = queryParts.join(' ').trim();
      if (query.isEmpty) return null;

      final results = await _searchApple(query);
      if (results == null || results.isEmpty) return null;

      // Filter and score candidates
      Map<String, dynamic>? best;
      double highestScore = -1.0;

      for (final track in results) {
        final attrs = track['attributes'] as Map<String, dynamic>?;
        if (attrs == null) continue;

        final durationMs = attrs['durationInMillis'] as num?;
        final trackSeconds = durationMs != null ? (durationMs / 1000).toInt() : null;

        if (seconds > 0 && trackSeconds != null && (trackSeconds - seconds).abs() > _durationToleranceSeconds) {
          continue;
        }

        final score = _score(attrs, cleanTitle, cleanArtist);
        if (score > highestScore) {
          highestScore = score;
          best = track;
        }
      }

      if (best == null) return null;
      final appleId = best['id']?.toString();
      if (appleId == null || appleId.isEmpty) return null;

      return await _fetchLyrics(appleId, info);
    } catch (e) {
      if (kDebugMode) {
        print('PaxSenixProvider error for "${info.title}": $e');
      }
      return null;
    }
  }

  static double _score(Map<String, dynamic> attrs, String title, String artist) {
    final name = (attrs['name'] as String? ?? '').trim().toLowerCase();
    final targetTitle = title.trim().toLowerCase();
    final artistName = (attrs['artistName'] as String? ?? '').trim().toLowerCase();
    final targetArtist = artist.trim().toLowerCase();

    double score = 0.0;
    if (name == targetTitle) {
      score += 80.0;
    } else if (name.contains(targetTitle) || targetTitle.contains(name)) {
      score += 40.0;
    }

    if (artistName.contains(targetArtist) || targetArtist.contains(artistName)) {
      score += 40.0;
    }

    return score;
  }

  Future<List<Map<String, dynamic>>?> _searchApple(String query) async {
    final token = await _getToken();
    if (token == null) return null;

    final uri = Uri.parse('$_appleSearch?term=${Uri.encodeComponent(query)}&types=songs&limit=10&l=en-US');
    try {
      final res = await _client.get(
        uri,
        headers: {
          'Authorization': 'Bearer $token',
          'Origin': 'https://music.apple.com',
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        },
      ).timeout(_timeout);

      if (res.statusCode == 401 || res.statusCode == 403) {
        _cachedToken = null;
        return null;
      }

      if (res.statusCode != 200) return null;

      final json = jsonDecode(res.body);
      final songs = json['results']?['songs']?['data'] as List?;
      if (songs == null) return null;

      return songs.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (e) {
      return null;
    }
  }

  Future<LyricResult?> _fetchLyrics(String appleId, LyricsSearchInfo info) async {
    final url = Uri.parse('$_proxy/apple-music/lyrics?id=$appleId');
    try {
      final res = await _client.get(
        url,
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Accept': 'application/json',
        },
      ).timeout(_timeout);

      if (res.statusCode != 200) return null;

      final json = jsonDecode(res.body);
      if (json is! Map) return null;

      // 1. TTML word/syllable content
      final ttml = json['ttmlContent'] as String?;
      if (ttml != null && ttml.trim().isNotEmpty) {
        final lines = await TTMLParser.parse(ttml);
        if (lines.isNotEmpty) {
          final processed = lines.withBackgroundVocals().withInstrumentalGaps();
          if (kDebugMode) {
            print('PaxSenix: Parsed ${processed.length} TTML lines for "${info.title}"');
          }
          return LyricResult(
            title: info.title,
            artists: [info.artist],
            lines: processed,
            source: name,
          );
        }
      }

      // 2. Enhanced LRC multi-person or standard elrc
      final elrc = (json['elrcMultiPerson'] as String?) ?? (json['elrc'] as String?);
      if (elrc != null && elrc.trim().isNotEmpty) {
        final parsed = EnhancedLrcParser.parse(elrc);
        if (parsed.isNotEmpty) {
          final processed = parsed.withBackgroundVocals().withInstrumentalGaps();
          return LyricResult(
            title: info.title,
            artists: [info.artist],
            lines: processed,
            source: name,
          );
        }
      }

      return null;
    } catch (e) {
      return null;
    }
  }

  Future<String?> _getToken() async {
    if (_cachedToken != null &&
        _tokenFetchedAt != null &&
        DateTime.now().difference(_tokenFetchedAt!).inHours < 12) {
      return _cachedToken;
    }

    try {
      final homeRes = await _client.get(
        Uri.parse('https://music.apple.com/us/new'),
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        },
      ).timeout(const Duration(seconds: 8));

      if (homeRes.statusCode != 200) return null;

      final scriptMatch = RegExp(r'/assets/index~[^"]+\.js').firstMatch(homeRes.body);
      if (scriptMatch == null) return null;

      final scriptRes = await _client.get(
        Uri.parse('https://music.apple.com${scriptMatch.group(0)!}'),
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        },
      ).timeout(const Duration(seconds: 8));

      if (scriptRes.statusCode != 200) return null;

      final tokenMatch = RegExp(r'eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+').firstMatch(scriptRes.body);
      if (tokenMatch != null) {
        _cachedToken = tokenMatch.group(0);
        _tokenFetchedAt = DateTime.now();
        return _cachedToken;
      }
    } catch (e) {
      if (kDebugMode) {
        print('PaxSenix token scrape error: $e');
      }
    }
    return null;
  }
}
