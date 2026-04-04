import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:archive/archive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import '../models/comic.dart';
import 'package:pdfx/pdfx.dart';

class ComicService {
  static const String _comicsKey = 'saved_comics';

  // ─── Thumbnail ────────────────────────────────────────────────────────────

  static Future<String> getThumbnailPath(String fileName) async {
    final appDir = await getApplicationDocumentsDirectory();
    final thumbDir = Directory(p.join(appDir.path, 'thumbnails'));
    if (!thumbDir.existsSync()) await thumbDir.create(recursive: true);
    return p.join(thumbDir.path, '${fileName.hashCode}.jpg');
  }

  // ─── Pick file ────────────────────────────────────────────────────────────

  static Future<List<Comic>> pickAndParseComics() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: ['cbz', 'cbr', 'pdf', 'zip'],
      withData: false,
      withReadStream: false,
    );

    if (result == null) return [];

    final existing = await loadComics();
    final existingIds = existing.map((c) => c.id).toSet();
    List<Comic> newComics = [];

    for (var file in result.files) {
      final filePath = file.path;
      if (filePath == null) continue;

      final fileName = p.basename(filePath);
      final ext = p.extension(fileName).toLowerCase();
      final name = p.basenameWithoutExtension(fileName);
      final type = _detectType(ext);
      final id = filePath.hashCode.toRadixString(16);

      if (existingIds.contains(id)) continue;

      final seriesTitle = ComicTitleParser.parseSeriesTitle(name);
      final volumeNumber = ComicTitleParser.parseVolumeNumber(name);

      String? thumbnailPath;
      if (type == ComicFileType.cbz) {
        try {
          final thumb = await compute(_extractFirstCBZPage, filePath);
          if (thumb != null) {
            thumbnailPath = await getThumbnailPath(fileName);
            await File(thumbnailPath).writeAsBytes(thumb);
          }
        } catch (e) {
          debugPrint('CBZ thumbnail error: $e');
        }
      } else if (type == ComicFileType.pdf) {
        try {
          // Gunakan resolusi rendah untuk thumbnail saja
          final thumb = await _extractFirstPDFPage(
            filePath,
            thumbnailOnly: true,
          );
          if (thumb != null) {
            thumbnailPath = await getThumbnailPath(fileName);
            await File(thumbnailPath).writeAsBytes(thumb);
          }
        } catch (e) {
          debugPrint('PDF thumbnail error: $e');
        }
      }

      newComics.add(
        Comic(
          id: id,
          title: name,
          subtitle: type.name.toUpperCase(),
          imageUrl: '',
          coverBytes: null,
          thumbnailPath: thumbnailPath,
          progress: 0.0,
          genre: 'Local File',
          localPath: filePath,
          source: ComicSource.local,
          fileType: type,
          description: 'Local comic file: $fileName',
          seriesTitle: seriesTitle,
          volumeNumber: volumeNumber,
        ),
      );
      existingIds.add(id);
    }

    if (newComics.isNotEmpty) {
      await saveComics([...existing, ...newComics]);
    }
    return newComics;
  }

  // ─── Save & Load ──────────────────────────────────────────────────────────

  static Future<void> saveComics(List<Comic> comics) async {
    final prefs = await SharedPreferences.getInstance();
    final data = jsonEncode(comics.map((c) => c.toJson()).toList());
    await prefs.setString(_comicsKey, data);
  }

  static Future<List<Comic>> loadComics() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_comicsKey);
    if (jsonStr == null) return [];
    try {
      final List decoded = jsonDecode(jsonStr);
      return decoded.map((e) => Comic.fromJson(e)).toList();
    } catch (e) {
      debugPrint('Load error: $e');
      return [];
    }
  }

  // ─── Group by Series ──────────────────────────────────────────────────────

  static List<ComicSeries> groupBySeries(List<Comic> comics) {
    final Map<String, List<Comic>> grouped = {};

    for (final comic in comics) {
      grouped.putIfAbsent(comic.seriesTitle, () => []).add(comic);
    }

    final seriesList =
        grouped.entries.map((entry) {
          final volumes = [...entry.value]..sort(
            (a, b) => (a.volumeNumber ?? 999).compareTo(b.volumeNumber ?? 999),
          );
          return ComicSeries(seriesTitle: entry.key, volumes: volumes);
        }).toList();

    seriesList.sort((a, b) {
      final aRead = a.lastRead ?? 0;
      final bRead = b.lastRead ?? 0;
      if (aRead != bRead) return bRead.compareTo(aRead);
      return a.seriesTitle.compareTo(b.seriesTitle);
    });

    return seriesList;
  }

  // ─── Sync ─────────────────────────────────────────────────────────────────

  static Future<List<Comic>> syncWithFolder() async {
    final existing = await loadComics();

    final updated =
        existing.where((comic) {
          if (comic.localPath == null) return true;
          return File(comic.localPath!).existsSync();
        }).toList();

    await saveComics(updated);
    return updated;
  }

  // ─── Delete ───────────────────────────────────────────────────────────────

  static Future<void> deleteComic(
    Comic comic, {
    bool deleteFile = false,
  }) async {
    final comics = await loadComics();
    await saveComics(comics.where((c) => c.id != comic.id).toList());

    if (comic.thumbnailPath != null) {
      final thumb = File(comic.thumbnailPath!);
      if (thumb.existsSync()) await thumb.delete();
    }

    if (deleteFile && comic.localPath != null) {
      final file = File(comic.localPath!);
      if (file.existsSync()) await file.delete();
    }
  }

  static Future<void> deleteSeries(
    ComicSeries series, {
    bool deleteFiles = false,
  }) async {
    for (final comic in series.volumes) {
      await deleteComic(comic, deleteFile: deleteFiles);
    }
  }

  // ─── Update progress ──────────────────────────────────────────────────────

  static Future<void> updateComicProgress(
    String id,
    double progress, {
    int? currentPage,
    int? totalPages,
  }) async {
    final comics = await loadComics();
    final index = comics.indexWhere((c) => c.id == id);
    if (index != -1) {
      final old = comics[index];
      comics[index] = Comic(
        id: old.id,
        title: old.title,
        subtitle: old.subtitle,
        imageUrl: old.imageUrl,
        coverBytes: old.coverBytes,
        thumbnailPath: old.thumbnailPath,
        progress: progress,
        genre: old.genre,
        publisher: old.publisher,
        releaseYear: old.releaseYear,
        writer: old.writer,
        artist: old.artist,
        description: old.description,
        pages: old.pages,
        localPath: old.localPath,
        source: old.source,
        fileType: old.fileType,
        lastRead: DateTime.now().millisecondsSinceEpoch,
        currentPage: currentPage ?? old.currentPage,
        totalPages: totalPages ?? old.totalPages,
        seriesTitle: old.seriesTitle,
        volumeNumber: old.volumeNumber,
      );
      await saveComics(comics);
    }
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────

  static ComicFileType _detectType(String ext) {
    switch (ext) {
      case '.cbz':
      case '.zip':
        return ComicFileType.cbz;
      case '.cbr':
      case '.rar':
        return ComicFileType.cbr;
      case '.pdf':
        return ComicFileType.pdf;
      default:
        return ComicFileType.unknown;
    }
  }

  // ─── CBZ extraction ───────────────────────────────────────────────────────

  static Uint8List? _extractFirstCBZPage(String path) {
    try {
      final file = File(path);
      if (!file.existsSync()) return null;

      final archive = ZipDecoder().decodeBytes(file.readAsBytesSync());
      final images =
          archive.files.where((f) {
              if (!f.isFile) return false;
              final name = f.name.toLowerCase();
              if (name.contains('__macosx') ||
                  name.split('/').last.startsWith('.'))
                return false;
              return [
                '.jpg',
                '.png',
                '.jpeg',
                '.webp',
              ].contains(p.extension(name));
            }).toList()
            ..sort((a, b) => a.name.compareTo(b.name));

      if (images.isNotEmpty) {
        final content = images.first.content;
        if (content is Uint8List) return content;
        if (content is List<int>) return Uint8List.fromList(content);
      }
    } catch (e) {
      debugPrint('CBZ thumbnail error: $e');
    }
    return null;
  }

  static Future<List<Uint8List>> getPagesFromCBZ(String path) async {
    return compute(_extractCBZPages, path);
  }

  static List<Uint8List> _extractCBZPages(String path) {
    try {
      final file = File(path);
      if (!file.existsSync()) return [];

      final archive = ZipDecoder().decodeBytes(file.readAsBytesSync());
      final imageFiles =
          archive.files.where((f) {
              if (!f.isFile) return false;
              final name = f.name.toLowerCase();
              if (name.contains('__macosx') ||
                  name.split('/').last.startsWith('.'))
                return false;
              return [
                '.jpg',
                '.jpeg',
                '.png',
                '.webp',
              ].contains(p.extension(name));
            }).toList()
            ..sort((a, b) => a.name.compareTo(b.name));

      return imageFiles.map((f) {
        final content = f.content;
        if (content is Uint8List) return content;
        if (content is List<int>) return Uint8List.fromList(content);
        return Uint8List(0);
      }).toList();
    } catch (e) {
      debugPrint('CBZ extract error: $e');
      return [];
    }
  }

  // ─── CBZ lazy loading ─────────────────────────────────────────────────────

  static final Map<String, Archive> _openArchives = {};

  static Archive? _getOrOpenArchive(String path) {
    if (_openArchives.containsKey(path)) return _openArchives[path];
    try {
      final bytes = File(path).readAsBytesSync();
      final archive = ZipDecoder().decodeBytes(bytes);
      _openArchives[path] = archive;
      return archive;
    } catch (e) {
      debugPrint('Archive open error: $e');
      return null;
    }
  }

  static void closeArchive(String path) {
    _openArchives.remove(path);
  }

  static Future<List<String>> getPagePathsFromCBZ(String path) async {
    final archive = _getOrOpenArchive(path);
    if (archive == null) return [];
    return _listCBZPageNamesFromArchive(archive);
  }

  static List<String> _listCBZPageNamesFromArchive(Archive archive) {
    final imageEntries =
        archive.files.where((f) {
            if (!f.isFile) return false;
            final name = f.name.toLowerCase();
            if (name.contains('__macosx') ||
                name.split('/').last.startsWith('.'))
              return false;
            return [
              '.jpg',
              '.jpeg',
              '.png',
              '.webp',
            ].contains(p.extension(name));
          }).toList()
          ..sort((a, b) => a.name.compareTo(b.name));
    return imageEntries.map((f) => f.name).toList();
  }

  static Future<Uint8List> getPageBytes(
    String archivePath,
    String entryName,
  ) async {
    final archive = _getOrOpenArchive(archivePath);
    if (archive == null) return Uint8List(0);

    try {
      final entry = archive.files.firstWhere(
        (f) => f.name == entryName,
        orElse: () => ArchiveFile('', 0, Uint8List(0)),
      );
      final content = entry.content;
      if (content is Uint8List) return content;
      if (content is List<int>) return Uint8List.fromList(content);
    } catch (e) {
      debugPrint('CBZ page decode error ($entryName): $e');
    }
    return Uint8List(0);
  }

  // ─── PDF Document Cache ───────────────────────────────────────────────────

  /// Cache PdfDocument yang sudah dibuka — key: path file PDF.
  /// Dibuka sekali saat getPdfPageCount atau getPdfPageImage pertama kali,
  /// dipakai ulang untuk semua halaman, ditutup saat closePdfDocument
  /// dipanggil dari ReaderPage.dispose().
  static final Map<String, PdfDocument> _openPdfDocuments = {};

  /// Cache hasil render halaman PDF — key: "$path:$pageNumber:$scale".
  /// Halaman di luar radius ±[_pdfCacheRadius] dari halaman aktif di-evict
  /// melalui evictPdfPageCache().
  static final Map<String, Uint8List> _pdfPageCache = {};

  static const int _pdfCacheRadius = 3;

  /// Buka PDF (atau ambil dari cache) dan kembalikan jumlah halaman.
  static Future<int> getPdfPageCount(String path) async {
    final doc = await _getOrOpenPdfDocument(path);
    return doc?.pagesCount ?? 0;
  }

  static Future<PdfDocument?> _getOrOpenPdfDocument(String path) async {
    if (_openPdfDocuments.containsKey(path)) return _openPdfDocuments[path];
    try {
      final doc = await PdfDocument.openFile(path);
      _openPdfDocuments[path] = doc;
      return doc;
    } catch (e) {
      debugPrint('PDF open error: $e');
      return null;
    }
  }

  /// Render satu halaman PDF dengan cache.
  ///
  /// [pageNumber] dimulai dari 1.
  /// [scale] adalah faktor skala render terhadap ukuran asli halaman.
  /// Gunakan scale=1.5 untuk reader, scale=0.5 untuk thumbnail.
  static Future<Uint8List?> getPdfPageImage(
    String path,
    int pageNumber, {
    double scale = 1.5,
  }) async {
    final cacheKey = '$path:$pageNumber:$scale';
    if (_pdfPageCache.containsKey(cacheKey)) {
      return _pdfPageCache[cacheKey];
    }

    final doc = await _getOrOpenPdfDocument(path);
    if (doc == null) return null;

    try {
      final page = await doc.getPage(pageNumber);
      final pageImage = await page.render(
        width: page.width * scale,
        height: page.height * scale,
        format: PdfPageImageFormat.jpeg,
        backgroundColor: '#ffffff',
        quality: 85,
      );
      await page.close();

      final bytes = pageImage?.bytes;
      if (bytes != null) {
        _pdfPageCache[cacheKey] = bytes;
      }
      return bytes;
    } catch (e) {
      debugPrint('PDF page render error (page $pageNumber): $e');
      return null;
    }
  }

  /// Pre-fetch halaman di sekitar [currentPage] secara background.
  /// Dipanggil dari ReaderPage setelah halaman aktif selesai ditampilkan.
  static Future<void> prefetchPdfPages(
    String path,
    int currentPage,
    int totalPages, {
    double scale = 1.5,
    int radius = 2,
  }) async {
    final start = (currentPage - radius).clamp(1, totalPages);
    final end = (currentPage + radius).clamp(1, totalPages);

    for (int i = start; i <= end; i++) {
      if (i == currentPage) continue;
      final cacheKey = '$path:$i:$scale';
      if (_pdfPageCache.containsKey(cacheKey)) continue;
      // Fire-and-forget, tidak perlu await
      getPdfPageImage(path, i, scale: scale).ignore();
    }
  }

  /// Buang cache halaman yang terlalu jauh dari halaman aktif agar
  /// memory tidak membengkak saat baca PDF panjang.
  static void evictPdfPageCache(
    String path,
    int currentPage, {
    double scale = 1.5,
  }) {
    final keysToRemove =
        _pdfPageCache.keys.where((key) {
          if (!key.startsWith('$path:')) return false;
          final parts = key.split(':');
          // format: "path:pageNumber:scale"
          if (parts.length < 3) return false;
          final pageNum = int.tryParse(parts[parts.length - 2]);
          if (pageNum == null) return false;
          return (pageNum - currentPage).abs() > _pdfCacheRadius;
        }).toList();

    for (final key in keysToRemove) {
      _pdfPageCache.remove(key);
    }
  }

  /// Tutup PdfDocument dan bersihkan semua cache halaman untuk path ini.
  /// Dipanggil dari ReaderPage.dispose().
  static Future<void> closePdfDocument(String path) async {
    final doc = _openPdfDocuments.remove(path);
    await doc?.close();

    // Bersihkan semua cache halaman untuk dokumen ini
    _pdfPageCache.removeWhere((key, _) => key.startsWith('$path:'));
  }

  // ─── PDF Thumbnail (internal) ─────────────────────────────────────────────

  /// Ekstrak halaman pertama PDF untuk thumbnail.
  /// [thumbnailOnly] = true → resolusi rendah (lebar maks 400px).
  static Future<Uint8List?> _extractFirstPDFPage(
    String path, {
    bool thumbnailOnly = false,
  }) async {
    PdfDocument? document;
    final bool ownDocument = !_openPdfDocuments.containsKey(path);
    try {
      document =
          thumbnailOnly
              // Untuk thumbnail, buka dokumen sementara tanpa cache
              ? await PdfDocument.openFile(path)
              : await _getOrOpenPdfDocument(path);

      if (document == null || document.pagesCount == 0) return null;

      final page = await document.getPage(1);

      // Untuk thumbnail: skala ke lebar maks 400px agar tidak boros memori
      final double scale =
          thumbnailOnly ? (400.0 / page.width).clamp(0.1, 1.0) : 2.0;

      final pageImage = await page.render(
        width: page.width * scale,
        height: page.height * scale,
        format: PdfPageImageFormat.jpeg,
        backgroundColor: '#ffffff',
        quality: thumbnailOnly ? 80 : 90,
      );
      await page.close();
      return pageImage?.bytes;
    } catch (e) {
      debugPrint('PDF thumbnail error: $e');
      return null;
    } finally {
      // Tutup hanya jika dokumen ini dibuka sementara untuk thumbnail
      if (thumbnailOnly && ownDocument) {
        await document?.close();
      }
    }
  }
}
