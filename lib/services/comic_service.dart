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
  static const String _externalLibraryKey = 'external_library_path';

  /// =========================
  /// THUMBNAIL PATH
  /// =========================
  static Future<String> getThumbnailPath(String fileName) async {
    final appDir = await getApplicationDocumentsDirectory();
    final thumbDir = Directory(p.join(appDir.path, 'thumbnails'));

    if (!thumbDir.existsSync()) {
      await thumbDir.create(recursive: true);
    }
    return p.join(thumbDir.path, '$fileName.jpg');
  }

  /// =========================
  /// PICK FILE (NO COPY)
  /// =========================
  static Future<List<Comic>> pickAndParseComics() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: ['cbz', 'cbr', 'pdf', 'zip', 'rar', 'tar'],
    );

    if (result == null) return [];

    List<Comic> comics = [];

    for (var file in result.files) {
      if (file.path == null) continue;

      final originalPath = file.path!;
      final extension = p.extension(file.name).toLowerCase();
      final name = p.basenameWithoutExtension(file.name);

      ComicFileType type = ComicFileType.unknown;
      if (extension == '.cbz' || extension == '.zip') {
        type = ComicFileType.cbz;
      } else if (extension == '.cbr' || extension == '.rar') {
        type = ComicFileType.cbr;
      } else if (extension == '.pdf') {
        type = ComicFileType.pdf;
      }

      Uint8List? thumbnail;
      String? thumbnailPath;

      if (type == ComicFileType.cbz) {
        thumbnail = await compute(_extractFirstCBZPage, originalPath);

        if (thumbnail != null) {
          thumbnailPath = await getThumbnailPath(file.name);
          await File(thumbnailPath).writeAsBytes(thumbnail);
        }
      }

      comics.add(
        Comic(
          id: DateTime.now().millisecondsSinceEpoch.toString() + file.name,
          title: name,
          subtitle: type.name.toUpperCase(),
          imageUrl: '',
          coverBytes: null, // ❌ tidak simpan di memory lagi
          thumbnailPath: thumbnailPath, // ✅ pakai file
          progress: 0.0,
          genre: 'Local File',
          localPath: originalPath,
          source: ComicSource.local,
          fileType: type,
          description: 'Local comic file: ${file.name}',
        ),
      );
    }

    final existing = await loadComics();
    final updated = [...existing, ...comics];
    await saveComics(updated);

    return comics;
  }

  /// =========================
  /// SAVE & LOAD
  /// =========================
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

  /// =========================
  /// REMOVE (SAFE)
  /// =========================
  static Future<void> removeFromLibrary(Comic comic) async {
    final comics = await loadComics();
    final updated = comics.where((c) => c.id != comic.id).toList();
    await saveComics(updated);

    // delete thumbnail only
    if (comic.thumbnailPath != null) {
      final file = File(comic.thumbnailPath!);
      if (file.existsSync()) {
        await file.delete();
      }
    }
  }

  /// =========================
  /// DELETE (FULL)
  /// =========================
  static Future<void> deleteComic(
    Comic comic, {
    bool deleteFile = false,
  }) async {
    final comics = await loadComics();
    final updatedComics = comics.where((c) => c.id != comic.id).toList();
    await saveComics(updatedComics);

    // ✅ delete thumbnail
    if (comic.thumbnailPath != null) {
      final thumb = File(comic.thumbnailPath!);
      if (thumb.existsSync()) {
        await thumb.delete();
      }
    }

    // ✅ optional delete file
    if (deleteFile && comic.localPath != null) {
      final file = File(comic.localPath!);
      if (file.existsSync()) {
        await file.delete();
      }
    }
  }

  /// =========================
  /// EXTERNAL LIBRARY
  /// =========================
  static Future<String?> pickLibraryDirectory() async {
    final dir = await FilePicker.platform.getDirectoryPath();

    if (dir != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_externalLibraryKey, dir);
    }

    return dir;
  }

  static Future<String?> getExternalLibraryPath() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_externalLibraryKey);
  }

  /// =========================
  /// SYNC FOLDER
  /// =========================
  static Future<List<Comic>> syncWithFolder() async {
    final externalPath = await getExternalLibraryPath();
    final existing = await loadComics();

    List<Comic> updated = List.from(existing);
    bool changed = false;

    if (externalPath != null) {
      changed |= await _scanDir(externalPath, updated);
    }

    // remove missing files
    updated =
        updated.where((comic) {
          if (comic.localPath == null) return true;
          return File(comic.localPath!).existsSync();
        }).toList();

    if (changed) {
      await saveComics(updated);
    }

    return updated;
  }

  static Future<bool> _scanDir(String path, List<Comic> list) async {
    bool changed = false;

    final dir = Directory(path);
    if (!dir.existsSync()) return false;

    final files = dir.listSync(recursive: true);

    for (var entity in files) {
      if (entity is! File) continue;

      final filePath = p.normalize(entity.path);
      final fileName = p.basename(filePath);
      final ext = p.extension(fileName).toLowerCase();

      if (!['.cbz', '.cbr', '.pdf', '.zip', '.rar'].contains(ext)) continue;

      final exists = list.any(
        (c) => p.normalize(c.localPath ?? '') == filePath,
      );

      if (!exists) {
        String? thumbnailPath;

        if (ext == '.cbz' || ext == '.zip') {
          try {
            final thumb = await compute(_extractFirstCBZPage, filePath);
            if (thumb != null) {
              thumbnailPath = await getThumbnailPath(fileName);
              await File(thumbnailPath).writeAsBytes(thumb);
            }
          } catch (_) {}
        }

        list.add(
          Comic(
            id: '${DateTime.now().millisecondsSinceEpoch}_${fileName.hashCode}',
            title: p.basenameWithoutExtension(fileName),
            subtitle: ext.replaceAll('.', '').toUpperCase(),
            imageUrl: '',
            coverBytes: null,
            thumbnailPath: thumbnailPath,
            progress: 0,
            genre: 'Local File',
            localPath: filePath,
            source: ComicSource.local,
            fileType: ComicFileType.cbz,
          ),
        );

        changed = true;
      }
    }

    return changed;
  }

  /// =========================
  /// UPDATE PROGRESS
  /// =========================
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
        thumbnailPath: old.thumbnailPath, // 🔥 penting (jangan hilang)
        progress: progress,
        genre: old.genre,
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

  /// =========================
  /// CBZ THUMBNAIL
  /// =========================
  static Uint8List? _extractFirstCBZPage(String path) {
    try {
      final file = File(path);
      if (!file.existsSync()) return null;

      final archive = ZipDecoder().decodeBytes(file.readAsBytesSync());

      final images =
          archive.files.where((f) {
            if (!f.isFile) return false;
            final ext = p.extension(f.name).toLowerCase();
            return ['.jpg', '.png', '.jpeg'].contains(ext);
          }).toList();

      images.sort((a, b) => a.name.compareTo(b.name));

      if (images.isNotEmpty) {
        final content = images.first.content;
        if (content is Uint8List) return content;
        if (content is List<int>) {
          return Uint8List.fromList(content);
        }
      }
    } catch (e) {
      debugPrint('CBZ error: $e');
    }

    return null;
  }

  /// PUBLIC METHOD (dipanggil dari Reader)
  static Future<List<Uint8List>> getPagesFromCBZ(String path) async {
    return compute(_extractCBZPages, path);
  }

  /// BACKGROUND FUNCTION (WAJIB top-level / static)
  static List<Uint8List> _extractCBZPages(String path) {
    try {
      final file = File(path);
      if (!file.existsSync()) return [];

      final bytes = file.readAsBytesSync();
      final archive = ZipDecoder().decodeBytes(bytes);

      final imageFiles =
          archive.files.where((f) {
            if (!f.isFile) return false;

            final name = f.name.toLowerCase();

            if (name.contains('__macosx') ||
                name.split('/').last.startsWith('.')) {
              return false;
            }

            final ext = p.extension(name);
            return ['.jpg', '.jpeg', '.png', '.webp'].contains(ext);
          }).toList();

      imageFiles.sort((a, b) => a.name.compareTo(b.name));

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
