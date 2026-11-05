import 'package:equatable/equatable.dart';

import 'track.dart';

/// A single podcast episode (a long-form YouTube video with an audio track).
class Episode extends Equatable {
  final String videoId;
  final String title;
  final String? description;
  final String? subtitle; // e.g. "114K views • 5d ago"
  final String? durationText; // e.g. "58 min"
  final Duration duration;
  final String? thumbnailUrl;
  final double progress; // 0..1 listened
  final bool isPlayed;
  // Show context (so an episode can stand alone in a queue).
  final String podcastId;
  final String podcastTitle;
  final String? podcastAuthor;

  const Episode({
    required this.videoId,
    required this.title,
    this.description,
    this.subtitle,
    this.durationText,
    this.duration = Duration.zero,
    this.thumbnailUrl,
    this.progress = 0.0,
    this.isPlayed = false,
    this.podcastId = '',
    this.podcastTitle = '',
    this.podcastAuthor,
  });

  /// Convert to a [Track] so it plays through the normal audio queue.
  Track toTrack() => Track(
        id: videoId,
        title: title,
        artist: podcastAuthor?.isNotEmpty == true
            ? podcastAuthor!
            : podcastTitle,
        album: podcastTitle,
        duration: duration,
        thumbnailUrl: thumbnailUrl,
        highResThumbnailUrl: thumbnailUrl,
        podcastId: podcastId.isNotEmpty ? podcastId : null,
      );

  Episode copyWith({double? progress, bool? isPlayed}) => Episode(
        videoId: videoId,
        title: title,
        description: description,
        subtitle: subtitle,
        durationText: durationText,
        duration: duration,
        thumbnailUrl: thumbnailUrl,
        progress: progress ?? this.progress,
        isPlayed: isPlayed ?? this.isPlayed,
        podcastId: podcastId,
        podcastTitle: podcastTitle,
        podcastAuthor: podcastAuthor,
      );

  Map<String, dynamic> toJson() => {
        'videoId': videoId,
        'title': title,
        'description': description,
        'subtitle': subtitle,
        'durationText': durationText,
        'durationMs': duration.inMilliseconds,
        'thumbnailUrl': thumbnailUrl,
        'progress': progress,
        'isPlayed': isPlayed,
        'podcastId': podcastId,
        'podcastTitle': podcastTitle,
        'podcastAuthor': podcastAuthor,
      };

  factory Episode.fromJson(Map<String, dynamic> json) => Episode(
        videoId: json['videoId'] as String,
        title: json['title'] as String? ?? '',
        description: json['description'] as String?,
        subtitle: json['subtitle'] as String?,
        durationText: json['durationText'] as String?,
        duration: Duration(milliseconds: (json['durationMs'] as num?)?.toInt() ?? 0),
        thumbnailUrl: json['thumbnailUrl'] as String?,
        progress: (json['progress'] as num?)?.toDouble() ?? 0.0,
        isPlayed: json['isPlayed'] as bool? ?? false,
        podcastId: json['podcastId'] as String? ?? '',
        podcastTitle: json['podcastTitle'] as String? ?? '',
        podcastAuthor: json['podcastAuthor'] as String?,
      );

  @override
  List<Object?> get props => [videoId, progress, isPlayed];
}

/// A podcast show and its episodes.
class Podcast extends Equatable {
  final String id; // the show's playlistId (PL...)
  final String title;
  final String? author;
  final String? authorId;
  final String? description;
  final String? thumbnailUrl;
  final List<Episode> episodes;
  final bool saved; // saved to the user's library
  final String? continuation; // token for more episodes

  const Podcast({
    required this.id,
    required this.title,
    this.author,
    this.authorId,
    this.description,
    this.thumbnailUrl,
    this.episodes = const [],
    this.saved = false,
    this.continuation,
  });

  Podcast copyWith({
    List<Episode>? episodes,
    bool? saved,
    String? continuation,
  }) =>
      Podcast(
        id: id,
        title: title,
        author: author,
        authorId: authorId,
        description: description,
        thumbnailUrl: thumbnailUrl,
        episodes: episodes ?? this.episodes,
        saved: saved ?? this.saved,
        continuation: continuation ?? this.continuation,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'author': author,
        'authorId': authorId,
        'description': description,
        'thumbnailUrl': thumbnailUrl,
        'saved': saved,
        'episodes': episodes.map((e) => e.toJson()).toList(),
      };

  factory Podcast.fromJson(Map<String, dynamic> json) => Podcast(
        id: json['id'] as String,
        title: json['title'] as String? ?? '',
        author: json['author'] as String?,
        authorId: json['authorId'] as String?,
        description: json['description'] as String?,
        thumbnailUrl: json['thumbnailUrl'] as String?,
        saved: json['saved'] as bool? ?? false,
        episodes: (json['episodes'] as List?)
                ?.map((e) => Episode.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
      );

  @override
  List<Object?> get props => [id, saved, episodes.length];
}
