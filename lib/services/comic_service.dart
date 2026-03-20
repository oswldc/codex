import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:archive/archive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import '../models/comic.dart';

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

      String? thumbnailPath;
      if (type == ComicFileType.cbz) {
        try {
          final thumb = await compute(_extractFirstCBZPage, filePath);
          if (thumb != null) {
            thumbnailPath = await getThumbnailPath(fileName);
            await File(thumbnailPath).writeAsBytes(thumb);
          }
        } catch (e) {
          debugPrint('Thumbnail error: $e');
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
}
