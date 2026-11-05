import 'lyrics_models.dart';

/// Extension to split trailing background/backing vocals in brackets
extension BackgroundVocalsExtension on List<LyricLine> {
  /// Pulls the answering vocal out of a line and hangs it underneath as a background line.
  List<LyricLine> withBackgroundVocals() {
    return map((line) => line.splitTrailingBracket()).toList();
  }
}

extension LyricLineBackgroundExtension on LyricLine {
  LyricLine splitTrailingBracket() {
    // If it already has background lines or is an instrumental gap, leave it alone
    if (backgroundLines.isNotEmpty || isBackground || isGap) return this;

    final open = _bracketStart(text);
    if (open == null) return this;

    final lead = text.substring(0, open).trimRight();
    final backing = text.substring(open).trim();
    if (lead.isEmpty || !backing.contains(RegExp(r'[a-zA-Z0-9\u00C0-\u024F\u1E00-\u1EFF\u0400-\u04FF\u0900-\u097F\u4E00-\u9FFF]'))) {
      return this;
    }

    final wordsList = words;
    if (wordsList == null || wordsList.isEmpty) {
      // Line-synced: share the line's timestamp
      return copyWith(
        text: lead,
        backgroundLines: [
          LyricLine(
            timeInMs: timeInMs,
            text: backing,
            durationMs: durationMs,
            sungUntilMs: sungUntilMs,
            isBackground: true,
          ),
        ],
      );
    }

    // Word-synced: find the word where the bracket starts
    final splitIndex = _findWordIndexAtCharOffset(wordsList, open);
    if (splitIndex == null || splitIndex <= 0 || splitIndex >= wordsList.length) {
      return this;
    }

    final leadWords = wordsList.sublist(0, splitIndex);
    final backingWords = wordsList.sublist(splitIndex);

    if (leadWords.isEmpty || backingWords.isEmpty) return this;

    final backingTime = backingWords.first.startTimeMs;

    return copyWith(
      text: lead,
      words: leadWords,
      backgroundLines: [
        LyricLine(
          timeInMs: backingTime,
          text: backingWords.map((w) => w.text).join(' '),
          words: backingWords,
          durationMs: durationMs,
          sungUntilMs: sungUntilMs,
          isBackground: true,
        ),
      ],
    );
  }

  static int? _bracketStart(String text) {
    int? candidate;
    for (int i = 0; i < text.length; i++) {
      final c = text[i];
      if (c == '(' || c == '[' || c == '（' || c == '【') {
        candidate = i;
      }
    }
    if (candidate == null || candidate == 0) return null;

    // Check if the closing bracket exists after open
    final openChar = text[candidate];
    final closeChar = openChar == '(' ? ')' : (openChar == '[' ? ']' : (openChar == '（' ? '）' : '】'));
    if (!text.substring(candidate).contains(closeChar)) return null;

    return candidate;
  }

  static int? _findWordIndexAtCharOffset(List<LyricWord> words, int charOffset) {
    int runningLength = 0;
    for (int i = 0; i < words.length; i++) {
      if (runningLength >= charOffset) return i;
      // words joined by space
      runningLength += words[i].text.length + 1;
      if (runningLength > charOffset) return i;
    }
    return null;
  }
}
