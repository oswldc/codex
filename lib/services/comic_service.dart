import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import '../models/comic.dart';
import 'package:pdfx/pdfx.dart';

class ComicService {
  static const String _comicsKey = 'saved_comics';

  // ─── In-memory cache ──────────────────────────────────────────────────────

  static List<Comic>? _cache;
  static bool _cacheDirty = false;

  static Future<List<Comic>> loadComics() async {
    if (_cache != null) return List.unmodifiable(_cache!);
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_comicsKey);
    if (jsonStr == null) {
      _cache = [];
      return [];
    }
    try {
      final List decoded = jsonDecode(jsonStr);
      _cache = decoded.map((e) => Comic.fromJson(e)).toList();
      return List.unmodifiable(_cache!);
    } catch (e) {
      debugPrint('Load error: $e');
      _cache = [];
      return [];
    }
  }

  static Future<void> saveComics(List<Comic> comics) async {
    _cache = List.of(comics);
    _cacheDirty = false;
    final prefs = await SharedPreferences.getInstance();
    final data = jsonEncode(comics.map((c) => c.toJson()).toList());
    await prefs.setString(_comicsKey, data);
  }

  static void saveNow() {
    if (_cache == null || !_cacheDirty) return;
    final snapshot = List.of(_cache!);
    _cacheDirty = false;
    SharedPreferences.getInstance().then((prefs) {
      final data = jsonEncode(snapshot.map((c) => c.toJson()).toList());
      prefs.setString(_comicsKey, data);
    });
  }

  // ─── Thumbnail ────────────────────────────────────────────────────────────

  static Future<String> getThumbnailPath(String fileName) async {
    final appDir = await getApplicationDocumentsDirectory();
    final thumbDir = Directory(p.join(appDir.path, 'thumbnails'));
    if (!thumbDir.existsSync()) await thumbDir.create(recursive: true);
    return p.join(thumbDir.path, '${fileName.hashCode}.jpg');
  }

  // ─── Pick file ────────────────────────────────────────────────────────────

  /// [onProgress] dipanggil setelah setiap file selesai diproses.
  ///   - [current]  : indeks file yang baru saja selesai (1-based)
  ///   - [total]    : total file yang akan diproses
  ///   - [fileName] : nama file yang baru saja selesai
  static Future<List<Comic>> pickAndParseComics({
    void Function(int current, int total, String fileName)? onProgress,
  }) async {
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

    // Hitung hanya file yang belum ada (yang akan benar-benar diproses)
    final filesToProcess =
        result.files.where((f) {
          if (f.path == null) return false;
          final id = f.path!.hashCode.toRadixString(16);
          return !existingIds.contains(id);
        }).toList();

    final total = filesToProcess.length;

    for (int i = 0; i < filesToProcess.length; i++) {
      final file = filesToProcess[i];
      final filePath = file.path!;

      final fileName = p.basename(filePath);
      final ext = p.extension(fileName).toLowerCase();
      final name = p.basenameWithoutExtension(fileName);
      final type = _detectType(ext);
      final id = filePath.hashCode.toRadixString(16);

      final seriesTitle = ComicTitleParser.parseSeriesTitle(name);
      final volumeNumber = ComicTitleParser.parseVolumeNumber(name);

      String? thumbnailPath;
      if (type == ComicFileType.cbz) {
        try {
          final thumb = await _extractFirstCBZPageSafe(filePath);
          if (thumb != null) {
            thumbnailPath = await getThumbnailPath(fileName);
            await File(thumbnailPath).writeAsBytes(thumb);
          }
        } catch (e) {
          debugPrint('CBZ thumbnail error: $e');
        }
      } else if (type == ComicFileType.pdf) {
        try {
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

      // Lapor progress setelah file ini selesai (1-based)
      onProgress?.call(i + 1, total, fileName);
    }

    if (newComics.isNotEmpty) {
      await saveComics([...existing, ...newComics]);
    }
    return newComics;
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
    if (_cache == null) await loadComics();

    final comics = _cache!;
    final index = comics.indexWhere((c) => c.id == id);
    if (index == -1) return;

    final old = comics[index];
    final double clampedProgress = progress.clamp(0.0, 1.0);

    comics[index] = Comic(
      id: old.id,
      title: old.title,
      subtitle: old.subtitle,
      imageUrl: old.imageUrl,
      coverBytes: old.coverBytes,
      thumbnailPath: old.thumbnailPath,
      progress: clampedProgress,
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

    _cacheDirty = true;
    _flushCacheAsync();
  }

  static void _flushCacheAsync() {
    if (_cache == null) return;
    final snapshot = List.of(_cache!);
    SharedPreferences.getInstance().then((prefs) {
      final data = jsonEncode(snapshot.map((c) => c.toJson()).toList());
      prefs.setString(_comicsKey, data).then((_) {
        _cacheDirty = false;
      });
    });
  }

  // ─── Next volume helper ───────────────────────────────────────────────────

  static Future<Comic?> getNextVolume(Comic comic) async {
    if (_cache == null) await loadComics();

    final sameSeriesVolumes =
        _cache!.where((c) => c.seriesTitle == comic.seriesTitle).toList()..sort(
          (a, b) => (a.volumeNumber ?? 999).compareTo(b.volumeNumber ?? 999),
        );

    final currentIndex = sameSeriesVolumes.indexWhere((c) => c.id == comic.id);

    if (currentIndex == -1) return null;
    if (currentIndex + 1 >= sameSeriesVolumes.length) return null;

    return sameSeriesVolumes[currentIndex + 1];
  }

  static Comic? getNextVolumeSync(Comic comic) {
    if (_cache == null) return null;

    final sameSeriesVolumes =
        _cache!.where((c) => c.seriesTitle == comic.seriesTitle).toList()..sort(
          (a, b) => (a.volumeNumber ?? 999).compareTo(b.volumeNumber ?? 999),
        );

    final currentIndex = sameSeriesVolumes.indexWhere((c) => c.id == comic.id);

    if (currentIndex == -1) return null;
    if (currentIndex + 1 >= sameSeriesVolumes.length) return null;

    return sameSeriesVolumes[currentIndex + 1];
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

  // ─── CBZ: Streaming ───────────────────────────────────────────────────────

  static final Map<String, Archive> _openArchives = {};
  static final Map<String, List<String>> _archivePageNames = {};

  static Archive? _getOrOpenArchive(String path) {
    if (_openArchives.containsKey(path)) return _openArchives[path];
    try {
      final inputStream = InputFileStream(path);
      final archive = ZipDecoder().decodeBuffer(inputStream);
      _openArchives[path] = archive;
      return archive;
    } catch (e) {
      debugPrint('Archive open error ($path): $e');
      return null;
    }
  }

  static void closeArchive(String path) {
    _openArchives.remove(path);
    _archivePageNames.remove(path);
  }

  static bool _isImageEntry(ArchiveFile f) {
    if (!f.isFile) return false;
    final name = f.name.toLowerCase();
    if (name.contains('__macosx')) return false;
    if (name.split('/').last.startsWith('.')) return false;
    return ['.jpg', '.jpeg', '.png', '.webp'].contains(p.extension(name));
  }

  static Future<List<String>> getPagePathsFromCBZ(String path) async {
    if (_archivePageNames.containsKey(path)) return _archivePageNames[path]!;
    final archive = _getOrOpenArchive(path);
    if (archive == null) return [];
    final names =
        archive.files.where(_isImageEntry).map((f) => f.name).toList()..sort();
    _archivePageNames[path] = names;
    return names;
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
      if (entry.name.isEmpty) return Uint8List(0);

      final content = entry.content;
      entry.clear();

      if (content is Uint8List) return content;
      if (content is List<int>) return Uint8List.fromList(content);
    } catch (e) {
      debugPrint('CBZ getPageBytes error ($entryName): $e');
    }
    return Uint8List(0);
  }

  static Future<List<Uint8List>> getPagesFromCBZ(String path) async {
    final pageNames = await getPagePathsFromCBZ(path);
    final List<Uint8List> result = [];
    for (final name in pageNames) {
      result.add(await getPageBytes(path, name));
    }
    return result;
  }

  // ─── CBZ Thumbnail ────────────────────────────────────────────────────────

  static Future<Uint8List?> _extractFirstCBZPageSafe(String path) async {
    try {
      final inputStream = InputFileStream(path);
      final archive = ZipDecoder().decodeBuffer(inputStream);

      final imageEntries =
          archive.files.where(_isImageEntry).toList()
            ..sort((a, b) => a.name.compareTo(b.name));

      if (imageEntries.isEmpty) return null;

      final content = imageEntries.first.content;
      if (content is Uint8List) return content;
      if (content is List<int>) return Uint8List.fromList(content);
    } catch (e) {
      debugPrint('CBZ thumbnail safe error ($path): $e');
    }
    return null;
  }

  // ─── PDF Document Cache ───────────────────────────────────────────────────

  static final Map<String, PdfDocument> _openPdfDocuments = {};
  static final Map<String, Uint8List> _pdfPageCache = {};
  static const int _pdfCacheRadius = 3;

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
      getPdfPageImage(path, i, scale: scale).ignore();
    }
  }

  static void evictPdfPageCache(
    String path,
    int currentPage, {
    double scale = 1.5,
  }) {
    final keysToRemove =
        _pdfPageCache.keys.where((key) {
          if (!key.startsWith('$path:')) return false;
          final parts = key.split(':');
          if (parts.length < 3) return false;
          final pageNum = int.tryParse(parts[parts.length - 2]);
          if (pageNum == null) return false;
          return (pageNum - currentPage).abs() > _pdfCacheRadius;
        }).toList();

    for (final key in keysToRemove) {
      _pdfPageCache.remove(key);
    }
  }

  static Future<void> closePdfDocument(String path) async {
    final doc = _openPdfDocuments.remove(path);
    await doc?.close();
    _pdfPageCache.removeWhere((key, _) => key.startsWith('$path:'));
  }

  // ─── PDF Thumbnail ────────────────────────────────────────────────────────

  static Future<Uint8List?> _extractFirstPDFPage(
    String path, {
    bool thumbnailOnly = false,
  }) async {
    PdfDocument? document;
    final bool ownDocument = !_openPdfDocuments.containsKey(path);
    try {
      document =
          thumbnailOnly
              ? await PdfDocument.openFile(path)
              : await _getOrOpenPdfDocument(path);

      if (document == null || document.pagesCount == 0) return null;

      final page = await document.getPage(1);
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
      if (thumbnailOnly && ownDocument) {
        await document?.close();
      }
    }
  }
}
