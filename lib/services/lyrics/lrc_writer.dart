import 'lyrics_models.dart';

const String kWordLyricsField = 'INZX_LYRICS';

/// Extension to write LyricLines back to standard LRC or Enhanced A2 LRC strings.
extension LrcWriterExtension on List<LyricLine> {
  /// Turns parsed lines back into standard LRC text ([mm:ss.xx]Text).
  /// Word timestamps are deliberately omitted so that standard players can render cleanly.
  String toLrc() {
    if (isEmpty) return '';

    // Plain unsynced lyrics have no timestamps - emit clean text lines
    if (every((line) => line.timeInMs <= 0)) {
      return where((line) => !line.isGap).map((line) => line.flattenedText).join('\n');
    }

    final sorted = toList()..sort((a, b) => a.timeInMs.compareTo(b.timeInMs));
    final buffer = StringBuffer();

    for (final line in sorted) {
      if (line.isGap) continue;
      buffer.writeln('${_formatStamp(line.timeInMs)}${line.flattenedText}');
    }

    return buffer.toString().trim();
  }

  /// Writes lines into Enhanced A2 LRC format with word timings kept.
  /// Example: `[00:12.34]<00:12.34>Hello <00:12.80>world`
  String toEnhancedLrc() {
    if (isEmpty) return '';
    final hasAnyWordSync = any((line) => line.hasWordSync);
    if (!hasAnyWordSync) return toLrc();

    final sorted = toList()..sort((a, b) => a.timeInMs.compareTo(b.timeInMs));
    final buffer = StringBuffer();

    for (final line in sorted) {
      if (line.isGap) continue;
      buffer.writeln('${_formatStamp(line.timeInMs)}${line.enhancedBody}');
    }

    return buffer.toString().trim();
  }

  static String _formatStamp(int timeMs) {
    final minutes = (timeMs ~/ 60000).toString().padLeft(2, '0');
    final seconds = ((timeMs % 60000) ~/ 1000).toString().padLeft(2, '0');
    final centis = ((timeMs % 1000) ~/ 10).toString().padLeft(2, '0');
    return '[$minutes:$seconds.$centis]';
  }
}

extension LyricLineFormatExtension on LyricLine {
  /// Flattened line including background vocals appended
  String get flattenedText {
    if (backgroundLines.isEmpty) return text;
    final bgText = backgroundLines.map((b) => b.text).join(' ');
    return (text.isNotEmpty ? '$text $bgText' : bgText).trim();
  }

  /// Line with word-level stamps
  String get enhancedBody {
    final wordsList = words;
    if (wordsList == null || wordsList.isEmpty) {
      return flattenedText;
    }

    final buffer = StringBuffer();
    var previous = timeInMs;

    for (int i = 0; i < wordsList.length; i++) {
      final word = wordsList[i];
      final start = word.startTimeMs < previous ? previous : word.startTimeMs;
      previous = start;

      final m = (start ~/ 60000).toString().padLeft(2, '0');
      final s = ((start % 60000) ~/ 1000).toString().padLeft(2, '0');
      final c = ((start % 1000) ~/ 10).toString().padLeft(2, '0');

      buffer.write('<$m:$s.$c>${word.text}');
      if (i < wordsList.length - 1) {
        buffer.write(' ');
      }
    }

    // Append closing timestamp for line end if known
    final lineEnd = endMs;
    if (lineEnd > previous) {
      final m = (lineEnd ~/ 60000).toString().padLeft(2, '0');
      final s = ((lineEnd % 60000) ~/ 1000).toString().padLeft(2, '0');
      final c = ((lineEnd % 1000) ~/ 10).toString().padLeft(2, '0');
      buffer.write('<$m:$s.$c>');
    }

    return buffer.toString();
  }
}
