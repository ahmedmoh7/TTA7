import 'dart:convert';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:http/http.dart' as http;
import 'lyrics_cleaner.dart';
import 'lyrics_models.dart';
import 'background_vocals.dart';
import 'instrumental_gaps.dart';

/// KuGou provider - Chinese, Asian & international catalog with audio hash search
class KuGouProvider implements LyricsProvider {
  @override
  String get name => 'KuGou';

  static const _durationToleranceSeconds = 8;
  static const _timeout = Duration(seconds: 8);
  static final http.Client _client = http.Client();

  @override
  Future<LyricResult?> search(LyricsSearchInfo info) async {
    try {
      final cleanTitle = LyricsCleaner.cleanTitle(info.title);
      final cleanArtist = LyricsCleaner.cleanArtist(info.artist);
      final seconds = info.durationSeconds;

      final keyword = '$cleanTitle - $cleanArtist';

      // 1. Search song hashes
      final hashes = await _searchSongHashes(keyword, seconds);

      // 2. Search lyrics candidate by hash
      Map<String, dynamic>? candidate;
      if (hashes != null && hashes.isNotEmpty) {
        for (final hash in hashes) {
          final found = await _searchLyrics(hash: hash);
          if (found != null && found.isNotEmpty) {
            candidate = found.first;
            break;
          }
        }
      }

      // 3. Fallback: Search lyrics candidate by keyword
      candidate ??= (await _searchLyrics(keyword: keyword, seconds: seconds))?.firstOrNull;

      if (candidate == null) return null;

      final id = candidate['id']?.toString();
      final accessKey = candidate['accesskey']?.toString();
      if (id == null || accessKey == null) return null;

      // 4. Download and decode base64 LRC
      final rawLrc = await _downloadLrc(id, accessKey);
      if (rawLrc == null || rawLrc.trim().isEmpty) return null;

      final strippedLrc = _stripCredits(rawLrc);
      final lines = _parseLrc(strippedLrc);
      if (lines.isEmpty) return null;

      final processed = lines.withBackgroundVocals().withInstrumentalGaps();

      if (kDebugMode) {
        print('KuGou: Found ${processed.length} lines for "$cleanTitle"');
      }

      return LyricResult(
        title: info.title,
        artists: [info.artist],
        lines: processed,
        source: name,
      );
    } catch (e) {
      if (kDebugMode) {
        print('KuGouProvider error: $e');
      }
      return null;
    }
  }

  Future<List<String>?> _searchSongHashes(String keyword, int seconds) async {
    final uri = Uri.parse(
      'https://mobileservice.kugou.com/api/v3/search/song',
    ).replace(queryParameters: {
      'version': '9108',
      'plat': '0',
      'pagesize': '8',
      'showtype': '0',
      'keyword': keyword,
    });

    try {
      final res = await _client.get(uri, headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      }).timeout(_timeout);

      if (res.statusCode != 200) return null;

      final json = jsonDecode(res.body);
      final infoList = json['data']?['info'] as List?;
      if (infoList == null) return null;

      final validCandidates = <Map<String, dynamic>>[];
      for (final item in infoList) {
        if (item is! Map) continue;
        final dur = (item['duration'] as num?)?.toInt() ?? -1;
        if (seconds <= 0 || (dur - seconds).abs() <= _durationToleranceSeconds) {
          validCandidates.add({
            'hash': item['hash']?.toString() ?? '',
            'diff': seconds > 0 && dur > 0 ? (dur - seconds).abs() : 0,
          });
        }
      }

      validCandidates.sort((a, b) => (a['diff'] as int).compareTo(b['diff'] as int));
      return validCandidates
          .map((e) => e['hash'] as String)
          .where((h) => h.isNotEmpty)
          .toList();
    } catch (_) {
      return null;
    }
  }

  Future<List<Map<String, dynamic>>?> _searchLyrics({
    String? hash,
    String? keyword,
    int? seconds,
  }) async {
    final params = <String, String>{
      'ver': '1',
      'man': 'yes',
      'client': 'pc',
    };
    if (hash != null) {
      params['hash'] = hash;
    } else if (keyword != null) {
      params['keyword'] = keyword;
      if (seconds != null && seconds > 0) {
        params['duration'] = (seconds * 1000).toString();
      }
    } else {
      return null;
    }

    final uri = Uri.parse('https://lyrics.kugou.com/search').replace(queryParameters: params);

    try {
      final res = await _client.get(uri, headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      }).timeout(_timeout);

      if (res.statusCode != 200) return null;

      final json = jsonDecode(res.body);
      final candidates = json['candidates'] as List?;
      if (candidates == null) return null;

      return candidates.map((c) => Map<String, dynamic>.from(c as Map)).toList();
    } catch (_) {
      return null;
    }
  }

  Future<String?> _downloadLrc(String id, String accessKey) async {
    final uri = Uri.parse('https://lyrics.kugou.com/download').replace(queryParameters: {
      'fmt': 'lrc',
      'charset': 'utf8',
      'client': 'pc',
      'ver': '1',
      'id': id,
      'accesskey': accessKey,
    });

    try {
      final res = await _client.get(uri, headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      }).timeout(_timeout);

      if (res.statusCode != 200) return null;

      final json = jsonDecode(res.body);
      final contentBase64 = json['content'] as String?;
      if (contentBase64 == null || contentBase64.isEmpty) return null;

      final decodedBytes = base64Decode(contentBase64);
      return utf8.decode(decodedBytes, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  /// Strips credit headers/footers (e.g. "Lyricist: ...", "Composer: ...")
  static String _stripCredits(String lrc) {
    final lines = lrc.split('\n');
    final stampedRegex = RegExp(r'^\[\d{1,3}:\d{2}[.:]\d{2,3}\].*');
    final creditRegex = RegExp(r'^\[\d{1,3}:\d{2}[.:]\d{2,3}\][^\[]+[:：].+');

    final validIndices = <int>[];
    for (int i = 0; i < lines.length; i++) {
      if (stampedRegex.hasMatch(lines[i].trim())) {
        validIndices.add(i);
      }
    }
    if (validIndices.isEmpty) return lrc;

    // Check head
    int headCut = 0;
    for (int i = 0; i < validIndices.length && i < 20; i++) {
      if (creditRegex.hasMatch(lines[validIndices[i]].trim())) {
        headCut = i + 1;
      }
    }

    // Check tail
    int tailCut = 0;
    for (int i = validIndices.length - 1; i >= 0 && i >= validIndices.length - 20; i--) {
      if (creditRegex.hasMatch(lines[validIndices[i]].trim())) {
        tailCut = validIndices.length - i;
      }
    }

    final surviving = validIndices.sublist(
      headCut,
      validIndices.length > tailCut ? validIndices.length - tailCut : validIndices.length,
    );

    return surviving.map((i) => lines[i]).join('\n');
  }

  static List<LyricLine> _parseLrc(String lrc) {
    final regex = RegExp(r'^\[(\d{1,3}):(\d{2})[.:](\d{2,3})\](.*)$');
    final result = <LyricLine>[];

    for (final raw in lrc.split('\n')) {
      final line = raw.trim();
      final match = regex.firstMatch(line);
      if (match != null) {
        final m = int.parse(match.group(1)!);
        final s = int.parse(match.group(2)!);
        final frac = match.group(3)!;
        final fracMs = frac.length == 3 ? int.parse(frac) : int.parse(frac) * 10;
        final text = match.group(4)?.trim() ?? '';
        if (text.isNotEmpty) {
          result.add(LyricLine(
            timeInMs: m * 60000 + s * 1000 + fracMs,
            text: text,
          ));
        }
      }
    }

    result.sort((a, b) => a.timeInMs.compareTo(b.timeInMs));
    return result;
  }
}
