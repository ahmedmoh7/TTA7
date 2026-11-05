import 'dart:math' as math;
import 'lyrics_models.dart';
import 'instrumental_gaps.dart';

/// Enhanced ("A2") LRC parser.
/// Parses lines with word-level timestamps:
/// `[00:27.39]<00:27.39>I <00:27.54>been <00:27.74>tryna <00:28.07>call`
class EnhancedLrcParser {
  static final RegExp _lineRegex = RegExp(
    r'^\[(\d{1,3}):(\d{2})[.:](\d{2,3})\](.*)$',
  );
  static final RegExp _wordRegex = RegExp(
    r'<(\d{1,3}):(\d{2})[.:](\d{2,3})>([^<]*)',
  );
  static const int _tailMs = 800;

  /// Parse enhanced LRC text into LyricLines. Returns empty list if no word timestamps are found.
  static List<LyricLine> parse(String lrc) {
    final rawLines = lrc.split('\n');
    final rows = <_Row>[];

    for (final raw in rawLines) {
      final line = raw.trim();
      final match = _lineRegex.firstMatch(line);
      if (match != null) {
        final timeMs = _parseStamp(match.group(1)!, match.group(2)!, match.group(3)!);
        final rest = match.group(4) ?? '';
        final wordMatches = _wordRegex.allMatches(rest).toList();
        rows.add(_Row(timeMs: timeMs, words: wordMatches, plain: rest.trim()));
      }
    }

    rows.sort((a, b) => a.timeMs.compareTo(b.timeMs));

    // If no line contains word-level stamps, this is standard LRC (not enhanced)
    if (rows.every((r) => r.words.isEmpty)) {
      return const [];
    }

    final result = <LyricLine>[];

    for (int index = 0; index < rows.length; index++) {
      final row = rows[index];
      if (row.words.isEmpty) {
        final text = decodeEntities(row.plain);
        if (text.isNotEmpty) {
          result.add(LyricLine(timeInMs: row.timeMs, text: text));
        }
        continue;
      }

      final lineEnd = (index + 1 < rows.length)
          ? rows[index + 1].timeMs
          : (_parseStampFromMatch(row.words.last) + _tailMs);

      final words = <LyricWord>[];
      for (int i = 0; i < row.words.length; i++) {
        final match = row.words[i];
        final text = decodeEntities(match.group(4) ?? '').trim();
        if (text.isEmpty) continue;

        final wordStart = _parseStampFromMatch(match);
        final wordEnd = (i + 1 < row.words.length)
            ? _parseStampFromMatch(row.words[i + 1])
            : lineEnd;

        words.add(LyricWord(
          text: text,
          startTimeMs: wordStart,
          endTimeMs: math.max(wordStart, wordEnd),
        ));
      }

      if (words.isEmpty) continue;

      final startTime = math.min(row.timeMs, words.first.startTimeMs);
      result.add(LyricLine(
        timeInMs: startTime,
        text: words.map((w) => w.text).join(' '),
        words: words,
      ));
    }

    return result.withInstrumentalGaps();
  }

  static int _parseStampFromMatch(Match match) {
    return _parseStamp(match.group(1)!, match.group(2)!, match.group(3)!);
  }

  static int _parseStamp(String minutes, String seconds, String fraction) {
    final m = int.parse(minutes);
    final s = int.parse(seconds);
    final fracMs = fraction.length == 3 ? int.parse(fraction) : int.parse(fraction) * 10;
    return m * 60000 + s * 1000 + fracMs;
  }

  /// Decodes HTML entities (e.g. &#x27; -> ', &apos; -> ', &quot; -> ")
  static String decodeEntities(String text) {
    if (!text.contains('&')) return text;
    var result = text;
    result = result.replaceAllMapped(
      RegExp(r'&#x([0-9a-fA-F]+);'),
      (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)),
    );
    result = result.replaceAllMapped(
      RegExp(r'&#(\d+);'),
      (m) => String.fromCharCode(int.parse(m.group(1)!)),
    );
    result = result.replaceAll('&apos;', "'");
    result = result.replaceAll('&quot;', '"');
    result = result.replaceAll('&nbsp;', ' ');
    result = result.replaceAll('&lt;', '<');
    result = result.replaceAll('&gt;', '>');
    result = result.replaceAll('&amp;', '&');
    return result;
  }
}

class _Row {
  final int timeMs;
  final List<Match> words;
  final String plain;

  _Row({required this.timeMs, required this.words, required this.plain});
}
