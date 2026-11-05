// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'downloaded_playlist_entity.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class DownloadedPlaylistEntityAdapter
    extends TypeAdapter<DownloadedPlaylistEntity> {
  @override
  final int typeId = 12;

  @override
  DownloadedPlaylistEntity read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return DownloadedPlaylistEntity(
      sourcePlaylistId: fields[0] as String,
      title: fields[1] as String,
      thumbnailUrl: fields[2] as String?,
      trackIds: (fields[3] as List).cast<String>(),
      trackTitles: (fields[4] as Map).cast<String, String>(),
      trackArtists: (fields[5] as Map).cast<String, String>(),
      createdAt: fields[6] as DateTime?,
      updatedAt: fields[7] as DateTime?,
    );
  }

  @override
  void write(BinaryWriter writer, DownloadedPlaylistEntity obj) {
    writer
      ..writeByte(8)
      ..writeByte(0)
      ..write(obj.sourcePlaylistId)
      ..writeByte(1)
      ..write(obj.title)
      ..writeByte(2)
      ..write(obj.thumbnailUrl)
      ..writeByte(3)
      ..write(obj.trackIds)
      ..writeByte(4)
      ..write(obj.trackTitles)
      ..writeByte(5)
      ..write(obj.trackArtists)
      ..writeByte(6)
      ..write(obj.createdAt)
      ..writeByte(7)
      ..write(obj.updatedAt);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DownloadedPlaylistEntityAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
