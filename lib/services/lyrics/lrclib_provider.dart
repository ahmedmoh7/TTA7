import 'dart:convert';
import 'package:flutter/foundation.dart' show compute, kDebugMode;
import 'package:http/http.dart' as http;
import 'lyrics_cleaner.dart';
import 'lyrics_models.dart';
import 'background_vocals.dart';
import 'instrumental_gaps.dart';

/// LRCLib provider - Free synced lyrics database
/// API docs: https://lrclib.net
class LRCLibProvider implements LyricsProvider {
  @override
  String get name => 'LRCLib';

  static const _baseUrl = 'https://lrclib.net';
  static const _requestTimeout = Duration(seconds: 8);
  static final http.Client _client = http.Client();

  @override
  Future<LyricResult?> search(LyricsSearchInfo info) async {
    try {
      // 1. Try exact match with raw metadata
      var result = await _searchExact(
        title: info.title,
        artist: info.artist,
        album: info.album,
        info: info,
      );
      if (result != null) return result;

      // 2. Try exact match with cleaned title & primary artist
      final cleanTitle = LyricsCleaner.cleanTitle(info.title);
      final cleanArtist = LyricsCleaner.cleanArtist(info.artist);
      if (cleanTitle != info.title || cleanArtist != info.artist) {
        result = await _searchExact(
          title: cleanTitle,
          artist: cleanArtist,
          album: null,
          info: info,
        );
        if (result != null) return result;
      }

      // 3. Try fuzzy search with cleaned query
      result = await _searchFuzzy('$cleanArtist $cleanTitle', info);
      if (result != null) return result;

      // 4. Try fuzzy search with cleaned title only
      result = await _searchFuzzy(cleanTitle, info);
      return result;
    } catch (e) {
      if (kDebugMode) {
        print('LRCLib error: $e');
      }
      return null;
    }
  }

  Future<LyricResult?> _searchExact({
    required String title,
    required String artist,
    String? album,
    required LyricsSearchInfo info,
  }) async {
    final params = {
      'artist_name': artist,
      'track_name': title,
      if (album != null && album.isNotEmpty) 'album_name': album,
    };

    final uri = Uri.parse(
      '$_baseUrl/api/search',
    ).replace(queryParameters: params);
    final response = await _client
        .get(uri, headers: {'Accept': 'application/json'})
        .timeout(_requestTimeout);

    if (response.statusCode != 200) return null;

    final data = jsonDecode(response.body) as List;
    if (data.isEmpty) return null;

    return await _findBestMatch(data, info);
  }

  Future<LyricResult?> _searchFuzzy(String query, LyricsSearchInfo info) async {
    final uri = Uri.parse(
      '$_baseUrl/api/search',
    ).replace(queryParameters: {'q': query});

    final response = await _client
        .get(uri, headers: {'Accept': 'application/json'})
        .timeout(_requestTimeout);

    if (response.statusCode != 200) return null;

    final data = jsonDecode(response.body) as List;
    if (data.isEmpty) return null;

    return await _findBestMatch(data, info);
  }

  Future<LyricResult?> _findBestMatch(
    List results,
    LyricsSearchInfo info,
  ) async {
    final cleanSearchArtist = LyricsCleaner.cleanArtist(info.artist).toLowerCase();
    final cleanSearchTitle = LyricsCleaner.cleanTitle(info.title).toLowerCase();

    // Filter by artist similarity
    final filtered = results.where((item) {
      final artistName = (item['artistName'] as String? ?? '').toLowerCase();
      final trackName = (item['trackName'] as String? ?? '').toLowerCase();

      // Check artist match
      if (artistName.contains(cleanSearchArtist) || cleanSearchArtist.contains(artistName)) {
        return true;
      }

      // Check title match
      if (trackName.contains(cleanSearchTitle) || cleanSearchTitle.contains(trackName)) {
        return true;
      }

      return false;
    }).toList();

    if (filtered.isEmpty) {
      filtered.addAll(results);
    }

    // Sort by duration difference
    filtered.sort((a, b) {
      final durA = (a['duration'] as num?)?.toDouble() ?? 0.0;
      final durB = (b['duration'] as num?)?.toDouble() ?? 0.0;
      final diffA = (durA - info.durationSeconds).abs();
      final diffB = (durB - info.durationSeconds).abs();
      return diffA.compareTo(diffB);
    });

    final closest = filtered.first;

    // Check duration is within 30 seconds tolerance (to support music videos with intro/outro)
    final duration = closest['duration'] as num?;
    if (info.durationSeconds > 0 && duration != null) {
      final durationDiff = (duration - info.durationSeconds).abs();
      if (durationDiff > 35) return null;
    }

    // Skip instrumental
    if (closest['instrumental'] == true) return null;

    final syncedLyrics = closest['syncedLyrics'] as String?;
    final plainLyrics = closest['plainLyrics'] as String?;

    if (syncedLyrics == null && plainLyrics == null) return null;

    // Parse synced lyrics in background isolate to avoid UI jank
    List<LyricLine>? lines;
    if (syncedLyrics != null && syncedLyrics.isNotEmpty) {
      final rawLines = await compute(_parseLrcIsolate, syncedLyrics);
      if (rawLines.isNotEmpty) {
        lines = rawLines.withBackgroundVocals().withInstrumentalGaps();
      } else {
        lines = rawLines;
      }
    }

    return LyricResult(
      title: closest['trackName'] as String? ?? info.title,
      artists: (closest['artistName'] as String? ?? info.artist)
          .split(RegExp(r'[&,]'))
          .map((s) => s.trim())
          .toList(),
      lines: lines,
      lyrics: plainLyrics,
      source: name,
    );
  }
}

/// Top-level function for compute() - parses LRC format lyrics
List<LyricLine> _parseLrcIsolate(String lrc) {
  final lines = <LyricLine>[];

  for (final line in lrc.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;

    // Match [mm:ss.xx] or [mm:ss:xx] format
    final match = RegExp(r'\[(\d+):(\d+)[.:](\d+)\](.*)').firstMatch(trimmed);
    if (match == null) continue;

    final minutes = int.parse(match.group(1)!);
    final seconds = int.parse(match.group(2)!);
    var ms = int.parse(match.group(3)!);

    // Handle different precision (2 digits = centiseconds, 3 digits = milliseconds)
    if (ms < 100) ms *= 10;

    final text = match.group(4)!.trim();

    lines.add(
      LyricLine(timeInMs: minutes * 60000 + seconds * 1000 + ms, text: text),
    );
  }

  // Sort by time
  lines.sort((a, b) => a.timeInMs.compareTo(b.timeInMs));

  return lines;
}
