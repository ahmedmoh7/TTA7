import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:http/http.dart' as http;
import 'lyrics_cleaner.dart';
import 'lyrics_models.dart';
import 'background_vocals.dart';
import 'instrumental_gaps.dart';

/// Musixmatch provider - signed API requests with desktop app token
/// API: https://apic.musixmatch.com/ws/1.1
class MusixmatchProvider implements LyricsProvider {
  @override
  String get name => 'Musixmatch';

  static const _baseUrl = 'https://apic.musixmatch.com/ws/1.1';
  static const _signingSecret = 'RJDefUswhwjkZDeM';
  static const _timeout = Duration(seconds: 10);
  static final http.Client _client = http.Client();

  static String? _cachedToken;
  static DateTime? _tokenFetchedAt;

  @override
  Future<LyricResult?> search(LyricsSearchInfo info) async {
    try {
      final cleanTitle = LyricsCleaner.cleanTitle(info.title);
      final cleanArtist = LyricsCleaner.cleanArtist(info.artist);
      final seconds = info.durationSeconds;

      final tracks = await _searchTrack(cleanTitle, cleanArtist);
      if (tracks == null || tracks.isEmpty) return null;

      // Score best candidate
      Map<String, dynamic>? bestTrack;
      double highestScore = -1.0;

      for (final t in tracks) {
        final score = _score(t, cleanTitle, cleanArtist, seconds);
        if (score > highestScore) {
          highestScore = score;
          bestTrack = t;
        }
      }

      if (bestTrack == null) return null;

      final trackId = bestTrack['track_id'];
      final hasSubtitles = bestTrack['has_subtitles'];
      if (trackId == null || hasSubtitles != 1) return null;

      final subtitleBody = await _fetchSubtitle(trackId.toString());
      if (subtitleBody == null || subtitleBody.trim().isEmpty) return null;

      final lines = _parseMxmSubtitle(subtitleBody);
      if (lines.isEmpty) return null;

      final processed = lines.withBackgroundVocals().withInstrumentalGaps();

      if (kDebugMode) {
        print('Musixmatch: Found ${processed.length} synced lines for "$cleanTitle"');
      }

      return LyricResult(
        title: info.title,
        artists: [info.artist],
        lines: processed,
        source: name,
      );
    } catch (e) {
      if (kDebugMode) {
        print('MusixmatchProvider error: $e');
      }
      return null;
    }
  }

  static double _score(Map<String, dynamic> track, String title, String artist, int seconds) {
    var score = 0.0;
    final name = (track['track_name'] as String? ?? '').trim().toLowerCase();
    final targetTitle = title.trim().toLowerCase();
    final artistName = (track['artist_name'] as String? ?? '').trim().toLowerCase();
    final targetArtist = artist.trim().toLowerCase();

    if (name == targetTitle) {
      score += 80.0;
    } else if (name.contains(targetTitle) || targetTitle.contains(name)) {
      score += 40.0;
    }

    if (artistName.contains(targetArtist) || targetArtist.contains(artistName)) {
      score += 40.0;
    }

    final trackLength = (track['track_length'] as num?)?.toInt();
    if (trackLength != null && seconds > 0) {
      final diff = (trackLength - seconds).abs();
      if (diff <= 2) {
        score += 30.0;
      } else if (diff <= 5) {
        score += 15.0;
      } else if (diff <= 10) {
        score += 5.0;
      } else {
        score -= 20.0;
      }
    }

    return score;
  }

  Future<List<Map<String, dynamic>>?> _searchTrack(String title, String artist) async {
    final response = await _signedGet((token) {
      final params = {
        'app_id': 'web-desktop-app-v1.0',
        'q_track': title,
        'q_artist': artist,
        'f_has_lyrics': '1',
        's_track_rating': 'desc',
        'quorum_factor': '1',
        'page_size': '10',
        'page': '1',
        'usertoken': token,
      };
      return Uri.parse('$_baseUrl/track.search').replace(queryParameters: params).toString();
    });

    if (response == null) return null;

    try {
      final json = jsonDecode(response);
      final trackList = json['message']?['body']?['track_list'] as List?;
      if (trackList == null) return null;

      final results = <Map<String, dynamic>>[];
      for (final item in trackList) {
        if (item is Map && item['track'] is Map) {
          results.add(Map<String, dynamic>.from(item['track'] as Map));
        }
      }
      return results;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _fetchSubtitle(String trackId) async {
    final response = await _signedGet((token) {
      final params = {
        'app_id': 'web-desktop-app-v1.0',
        'track_id': trackId,
        'subtitle_format': 'mxm',
        'usertoken': token,
      };
      return Uri.parse('$_baseUrl/track.subtitle.get').replace(queryParameters: params).toString();
    });

    if (response == null) return null;

    try {
      final json = jsonDecode(response);
      return json['message']?['body']?['subtitle']?['subtitle_body'] as String?;
    } catch (_) {
      return null;
    }
  }

  static List<LyricLine> _parseMxmSubtitle(String subtitleBody) {
    try {
      final items = jsonDecode(subtitleBody);
      if (items is! List) return const [];

      final lines = <LyricLine>[];
      for (final item in items) {
        if (item is! Map) continue;
        final text = (item['text'] as String?)?.trim() ?? '';
        if (text.isEmpty) continue;

        final time = item['time'];
        if (time is! Map) continue;
        final total = (time['total'] as num?)?.toDouble() ?? 0.0;
        final timeMs = (total * 1000).round();

        lines.add(LyricLine(
          timeInMs: timeMs,
          text: text,
        ));
      }

      lines.sort((a, b) => a.timeInMs.compareTo(b.timeInMs));
      return lines;
    } catch (_) {
      return const [];
    }
  }

  Future<String?> _signedGet(String Function(String token) urlBuilder) async {
    final token = await _getToken();
    if (token == null) return null;

    final url = urlBuilder(token);
    final signedUrl = _signUrl(url);

    try {
      final res = await _client.get(Uri.parse(signedUrl), headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      }).timeout(_timeout);

      if (_isTokenUnauthorized(res.body)) {
        _cachedToken = null;
        final freshToken = await _getToken();
        if (freshToken == null) return null;
        final freshUrl = _signUrl(urlBuilder(freshToken));
        final freshRes = await _client.get(Uri.parse(freshUrl)).timeout(_timeout);
        return freshRes.statusCode == 200 ? freshRes.body : null;
      }

      return res.statusCode == 200 ? res.body : null;
    } catch (_) {
      return null;
    }
  }

  static bool _isTokenUnauthorized(String body) {
    try {
      final json = jsonDecode(body);
      final code = json['message']?['header']?['status_code'];
      return code == 401 || code == 402;
    } catch (_) {
      return false;
    }
  }

  Future<String?> _getToken() async {
    if (_cachedToken != null &&
        _tokenFetchedAt != null &&
        DateTime.now().difference(_tokenFetchedAt!).inHours < 24) {
      return _cachedToken;
    }

    final rawUrl = '$_baseUrl/token.get?app_id=web-desktop-app-v1.0';
    final signed = _signUrl(rawUrl);

    try {
      final res = await _client.get(Uri.parse(signed), headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      }).timeout(_timeout);

      if (res.statusCode != 200) return null;
      final json = jsonDecode(res.body);
      final token = json['message']?['body']?['user_token'] as String?;
      if (token != null && token.isNotEmpty) {
        _cachedToken = token;
        _tokenFetchedAt = DateTime.now();
        return _cachedToken;
      }
    } catch (e) {
      if (kDebugMode) {
        print('Musixmatch token fetch error: $e');
      }
    }
    return null;
  }

  static String _signUrl(String url) {
    final now = DateTime.now().toUtc();
    final y = now.year.toString().padLeft(4, '0');
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    final dateStr = '$y$m$d';

    final toSign = utf8.encode('$url$dateStr');
    final key = utf8.encode(_signingSecret);
    final hmac = Hmac(sha256, key);
    final digest = hmac.convert(toSign);
    final signature = base64Encode(digest.bytes);

    return '$url&signature=${Uri.encodeComponent(signature)}&signature_protocol=sha256';
  }
}
