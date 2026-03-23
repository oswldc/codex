import 'dart:typed_data';
import 'dart:convert';

enum ComicSource { local, network }

enum ComicFileType { cbz, cbr, pdf, unknown }

class Comic {
  final String id;
  final String title;
  final String subtitle;
  final String imageUrl;
  final Uint8List? coverBytes;
  final double progress;
  final String genre;
  final String? publisher;
  final String? releaseYear;
  final String? writer;
  final String? artist;
  final String? description;
  final List<String> pages;
  final String? localPath;
  final ComicSource source;
  final ComicFileType fileType;
  final int? lastRead;
  final int? currentPage;
  final int? totalPages;
  final String? thumbnailPath;

  // ─── Fields baru untuk grouping ───────────────────────────────────────────
  /// Judul series yang sudah di-parse dari nama file
  /// Contoh: "Dragon Ball v01 (2003)..." → seriesTitle = "Dragon Ball"
  final String seriesTitle;

  /// Nomor volume yang sudah di-parse dari nama file
  /// Contoh: "Dragon Ball v01 (2003)..." → volumeNumber = 1
  /// null jika tidak ditemukan nomor volume
  final int? volumeNumber;

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
    String? seriesTitle,
    this.volumeNumber,
  }) : seriesTitle = seriesTitle ?? title;

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
      'seriesTitle': seriesTitle,
      'volumeNumber': volumeNumber,
    };
  }

  factory Comic.fromJson(Map<String, dynamic> json) {
    final title = json['title'] ?? '';
    return Comic(
      id: json['id'],
      title: title,
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
      // Kalau data lama belum punya seriesTitle, parse ulang dari title
      seriesTitle:
          json['seriesTitle'] ?? ComicTitleParser.parseSeriesTitle(title),
      volumeNumber:
          json['volumeNumber'] ?? ComicTitleParser.parseVolumeNumber(title),
    );
  }
}

// ─── Parser untuk nama file komik ─────────────────────────────────────────────

class ComicTitleParser {
  /// Parse series title dari nama file komik.
  ///
  /// Contoh:
  /// - "20th Century Boys, v01 (2000) [Band of the Hawks]" → "20th Century Boys"
  /// - "[Meganebuk] Vagabond Volume 22 (Eng)"              → "Vagabond"
  /// - "[Miku-PDF] Worst 1"                                → "Worst"
  /// - "Dragon Ball v01 (2003) (Digital) (LuCaZ)"         → "Dragon Ball"
  static String parseSeriesTitle(String rawTitle) {
    String title = rawTitle;

    // 1. Hapus prefix bracket di awal: [Meganebuk], [Miku-PDF], dll
    title = title.replaceAll(RegExp(r'^\[.*?\]\s*'), '');

    // 2. Hapus semua konten dalam tanda kurung: (2000), (Eng), (Digital)
    title = title.replaceAll(RegExp(r'\(.*?\)'), '');

    // 3. Hapus semua konten dalam bracket: [Band of the Hawks]
    title = title.replaceAll(RegExp(r'\[.*?\]'), '');

    // 4. Potong di titik kemunculan volume/chapter pattern:
    //    - ", v01"   - " v01"   - " Vol 1"   - " Volume 1"
    //    - " 001"    - "-001"   - " 1" (angka di akhir)
    title = title.replaceAll(
      RegExp(r'[,\s-]+(?:v|vol\.?|volume)\s*\d+.*$', caseSensitive: false),
      '',
    );

    // 5. Hapus angka standalone di akhir (misal: "Worst 1" → "Worst")
    title = title.replaceAll(RegExp(r'\s+\d+\s*$'), '');

    // 6. Bersihkan karakter sisa: koma, strip, spasi berlebih
    title = title.replaceAll(RegExp(r'[,\-_]+$'), '').trim();

    return title.isNotEmpty ? title : rawTitle;
  }

  /// Parse nomor volume dari nama file komik.
  ///
  /// Contoh:
  /// - "Dragon Ball v01 (2003)..."     → 1
  /// - "Vagabond Volume 22 (Eng)"      → 22
  /// - "Worst 1"                        → 1
  /// - "Batman_001"                     → 1
  /// - "One Piece" (tanpa nomor)        → null
  static int? parseVolumeNumber(String rawTitle) {
    // Coba pola v01, vol 1, vol. 1, volume 22 (paling prioritas)
    final volumeMatch = RegExp(
      r'(?:v|vol\.?|volume)\s*(\d+)',
      caseSensitive: false,
    ).firstMatch(rawTitle);
    if (volumeMatch != null) {
      return int.tryParse(volumeMatch.group(1)!);
    }

    // Coba nomor 3 digit setelah underscore atau spasi: _001, -001
    final paddedMatch = RegExp(r'[\s_-](\d{3})\b').firstMatch(rawTitle);
    if (paddedMatch != null) {
      return int.tryParse(paddedMatch.group(1)!);
    }

    // Coba angka di akhir string (setelah strip bracket & parentheses)
    String cleaned =
        rawTitle
            .replaceAll(RegExp(r'\(.*?\)'), '')
            .replaceAll(RegExp(r'\[.*?\]'), '')
            .trim();
    final trailingMatch = RegExp(r'\s+(\d+)\s*$').firstMatch(cleaned);
    if (trailingMatch != null) {
      return int.tryParse(trailingMatch.group(1)!);
    }

    return null;
  }
}

// ─── Model untuk grouping di library ─────────────────────────────────────────

class ComicSeries {
  final String seriesTitle;
  final List<Comic> volumes;

  const ComicSeries({required this.seriesTitle, required this.volumes});

  /// Volume pertama (dipakai sebagai cover series di library)
  Comic get representative {
    // Pilih volume dengan nomor terkecil, fallback ke index 0
    final sorted = [
      ...volumes,
    ]..sort((a, b) => (a.volumeNumber ?? 999).compareTo(b.volumeNumber ?? 999));
    return sorted.first;
  }

  /// Total jumlah volume dalam series ini
  int get volumeCount => volumes.length;

  /// Progress rata-rata semua volume
  double get averageProgress {
    if (volumes.isEmpty) return 0;
    return volumes.map((v) => v.progress).reduce((a, b) => a + b) /
        volumes.length;
  }

  /// Timestamp lastRead terbaru dari semua volume
  int? get lastRead {
    final reads = volumes.map((v) => v.lastRead).whereType<int>().toList();
    if (reads.isEmpty) return null;
    return reads.reduce((a, b) => a > b ? a : b);
  }
}
