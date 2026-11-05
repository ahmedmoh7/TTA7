import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import '../../models/track.dart';
import 'mp4_tagger.dart';
import 'id3_tagger.dart';
import 'webm_tagger.dart';

/// Orchestrates in-file metadata tagging (title, artist, album, synced lyrics, cover art)
/// across M4A, MP3, and WebM/Opus audio files.
class MediaTagger {
  static const int maxCoverDimension = 1000;

  /// Optimizes cover art to max 1000px on the longest side to avoid bloating the audio file
  static Uint8List? optimizeCoverArt(Uint8List? rawBytes) {
    if (rawBytes == null || rawBytes.isEmpty) return null;
    try {
      final decoded = img.decodeImage(rawBytes);
      if (decoded == null) return rawBytes;

      if (decoded.width <= maxCoverDimension &&
          decoded.height <= maxCoverDimension) {
        return rawBytes;
      }

      final resized = decoded.width >= decoded.height
          ? img.copyResize(decoded, width: maxCoverDimension)
          : img.copyResize(decoded, height: maxCoverDimension);

      return Uint8List.fromList(img.encodeJpg(resized, quality: 85));
    } catch (e) {
      if (kDebugMode) {
        print('MediaTagger: Cover optimization error: $e');
      }
      return rawBytes;
    }
  }

  /// Embeds metadata, lyrics, and cover art into the audio file in-place
  static Future<bool> tagFile({
    required File audioFile,
    required Track track,
    String? lyrics,
    Uint8List? coverArtBytes,
  }) async {
    try {
      if (!await audioFile.exists()) return false;

      final path = audioFile.path.toLowerCase();
      final bytes = await audioFile.readAsBytes();
      if (bytes.isEmpty) return false;

      final optimizedCover = optimizeCoverArt(coverArtBytes);
      final coverIsPng = optimizedCover != null &&
          optimizedCover.length >= 8 &&
          optimizedCover[0] == 0x89 &&
          optimizedCover[1] == 0x50; // PNG magic bytes

      Uint8List? taggedBytes;

      if (path.endsWith('.m4a') || path.endsWith('.mp4')) {
        taggedBytes = Mp4Tagger.tag(
          bytes,
          title: track.title,
          artist: track.artist,
          album: track.album,
          lyrics: lyrics,
          coverBytes: optimizedCover,
          coverIsPng: coverIsPng,
        );
      } else if (path.endsWith('.mp3')) {
        taggedBytes = Id3Tagger.tag(
          bytes,
          title: track.title,
          artist: track.artist,
          album: track.album,
          lyrics: lyrics,
          coverBytes: optimizedCover,
          coverIsPng: coverIsPng,
        );
      } else if (path.endsWith('.opus') || path.endsWith('.webm')) {
        taggedBytes = WebmTagger.tag(
          bytes,
          title: track.title,
          artist: track.artist,
          album: track.album,
          lyrics: lyrics,
          coverBytes: optimizedCover,
          coverIsPng: coverIsPng,
        );
      }

      if (taggedBytes != null && !identical(taggedBytes, bytes)) {
        // Atomic rewrite: write to .tagged temporary file then rename
        final tempFile = File('${audioFile.path}.tagged');
        await tempFile.writeAsBytes(taggedBytes, flush: true);
        if (await tempFile.exists() && await tempFile.length() > 0) {
          await tempFile.rename(audioFile.path);
          if (kDebugMode) {
            print(
              'MediaTagger: Successfully embedded tags & artwork into ${audioFile.path}',
            );
          }
          return true;
        }
      }
      return false;
    } catch (e) {
      if (kDebugMode) {
        print('MediaTagger: Failed to tag ${audioFile.path}: $e');
      }
      // Never fail the download because tagging failed
      return false;
    }
  }
}
