import 'dart:typed_data';
import 'dart:convert';

enum ComicSource { local, network }

enum ComicFileType { cbz, cbr, pdf, unknown }

class Comic {
  final String id;
  final String title;
  final String subtitle;
  final String imageUrl;
  final Uint8List? coverBytes; // For local cover images
  final double progress;
  final String genre;
  final String? publisher;
  final String? releaseYear;
  final String? writer;
  final String? artist;
  final String? description;
  final List<String> pages; // URLs for network comics
  final String? localPath;
  final ComicSource source;
  final ComicFileType fileType;
  final int? lastRead; // Timestamp for sorting recent comics
  final int? currentPage;
  final int? totalPages;
  final String? thumbnailPath;

  Comic({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.imageUrl,
    this.coverBytes,
    this.thumbnailPath,
    required this.progress,
    required this.genre,
    this.publisher,
    this.releaseYear,
    this.writer,
    this.artist,
    this.description,
    this.pages = const [],
    this.localPath,
    this.source = ComicSource.network,
    this.fileType = ComicFileType.unknown,
    this.lastRead,
    this.currentPage,
    this.totalPages,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'subtitle': subtitle,
      'imageUrl': imageUrl,
      'coverBytes': null,
      'thumbnailPath': thumbnailPath,
      'progress': progress,
      'genre': genre,
      'publisher': publisher,
      'releaseYear': releaseYear,
      'writer': writer,
      'artist': artist,
      'description': description,
      'pages': pages,
      'localPath': localPath,
      'source': source.index,
      'fileType': fileType.index,
      'lastRead': lastRead,
      'currentPage': currentPage,
      'totalPages': totalPages,
    };
  }

  factory Comic.fromJson(Map<String, dynamic> json) {
    return Comic(
      id: json['id'],
      title: json['title'],
      subtitle: json['subtitle'],
      imageUrl: json['imageUrl'] ?? '',
      coverBytes:
          json['coverBytes'] != null ? base64Decode(json['coverBytes']) : null,
      thumbnailPath: json['thumbnailPath'],
      progress: (json['progress'] as num?)?.toDouble() ?? 0.0,
      genre: json['genre'] ?? '',
      publisher: json['publisher'],
      releaseYear: json['releaseYear'],
      writer: json['writer'],
      artist: json['artist'],
      description: json['description'],
      pages: List<String>.from(json['pages'] ?? []),
      localPath: json['localPath'],
      source: ComicSource.values[json['source'] ?? 0],
      fileType: ComicFileType.values[json['fileType'] ?? 0],
      lastRead: json['lastRead'],
      currentPage: json['currentPage'],
      totalPages: json['totalPages'],
    );
  }
}
