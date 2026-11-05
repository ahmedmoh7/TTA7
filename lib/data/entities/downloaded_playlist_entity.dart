import 'package:hive/hive.dart';

part 'downloaded_playlist_entity.g.dart';

@HiveType(typeId: 12)
class DownloadedPlaylistEntity extends HiveObject {
  @HiveField(0)
  late String sourcePlaylistId;

  @HiveField(1)
  late String title;

  @HiveField(2)
  late String? thumbnailUrl;

  @HiveField(3)
  late List<String> trackIds;

  @HiveField(4)
  late Map<String, String> trackTitles;

  @HiveField(5)
  late Map<String, String> trackArtists;

  @HiveField(6)
  late DateTime createdAt;

  @HiveField(7)
  late DateTime updatedAt;

  DownloadedPlaylistEntity({
    required this.sourcePlaylistId,
    required this.title,
    this.thumbnailUrl,
    required this.trackIds,
    required this.trackTitles,
    required this.trackArtists,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();
}
