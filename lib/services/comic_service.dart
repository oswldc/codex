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

  static Future<List<Comic>> pickAndParseComics() async {
    try {
      debugPrint('ComicService: Calling file picker...');
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.custom,
        allowedExtensions: ['cbz', 'cbr', 'pdf', 'zip', 'rar', 'tar'],
        withData: false,
      );

      if (result == null) {
        debugPrint('ComicService: Picker returned null (cancelled)');
        return [];
      }

      // Get permanent directory for storage
      final appDir = await getApplicationDocumentsDirectory();
      final libraryDir = Directory(p.join(appDir.path, 'my_library'));
      if (!libraryDir.existsSync()) {
        await libraryDir.create(recursive: true);
      }

      List<Comic> comics = [];
      for (var file in result.files) {
        if (file.path == null) continue;

        // Copy file to permanent storage
        final permanentPath = p.normalize(p.join(libraryDir.path, file.name));
        final pickedFile = File(file.path!);

        debugPrint(
          'ComicService: Copying file to permanent storage: $permanentPath',
        );
        final permanentFile = await pickedFile.copy(permanentPath);

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
        try {
          if (type == ComicFileType.cbz) {
            thumbnail = await compute(_extractFirstCBZPage, permanentFile.path);
          }
        } catch (e) {
          debugPrint('Thumbnail extraction error: $e');
        }

        comics.add(
          Comic(
            id: DateTime.now().millisecondsSinceEpoch.toString() + file.name,
            title: name,
            subtitle: type.toString().split('.').last.toUpperCase(),
            imageUrl: '',
            coverBytes: thumbnail,
            progress: 0.0,
            genre: 'Local File',
            localPath: permanentFile.path,
            source: ComicSource.local,
            fileType: type,
            description: 'Local comic file: ${file.name}',
          ),
        );
      }
      return comics;
    } catch (e) {
      debugPrint('ComicService Error: $e');
      rethrow;
    }
  }

  static Future<void> saveComics(List<Comic> comics) async {
    final prefs = await SharedPreferences.getInstance();
    final String encodedData = jsonEncode(
      comics.map((comic) => comic.toJson()).toList(),
    );
    await prefs.setString(_comicsKey, encodedData);
  }

  static Future<List<Comic>> loadComics() async {
    final prefs = await SharedPreferences.getInstance();
    final String? comicsJson = prefs.getString(_comicsKey);
    if (comicsJson == null) return [];

    try {
      final List<dynamic> decodedData = jsonDecode(comicsJson);
      return decodedData.map((json) => Comic.fromJson(json)).toList();
    } catch (e) {
      debugPrint('Error loading comics: $e');
      return [];
    }
  }

  static Future<String> getLibraryPath() async {
    final appDir = await getApplicationDocumentsDirectory();
    final libraryDir = Directory(p.join(appDir.path, 'my_library'));
    if (!libraryDir.existsSync()) {
      await libraryDir.create(recursive: true);
    }
    return libraryDir.path;
  }

  static Future<String?> getExternalLibraryPath() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_externalLibraryKey);
  }

  static Future<String?> pickLibraryDirectory() async {
    try {
      String? selectedDirectory = await FilePicker.platform.getDirectoryPath();

      if (selectedDirectory != null) {
        // Create .ini file as a marker (try-catch because of Scoped Storage)
        try {
          final iniFile = File(p.join(selectedDirectory, 'codex_library.ini'));
          if (!iniFile.existsSync()) {
            await iniFile.writeAsString(
              '[Codex]\ndirectory_type=library\ncreated_at=${DateTime.now().toIso8601String()}',
            );
          }
        } catch (e) {
          debugPrint(
            'ComicService: Could not write .ini marker (expected on Android 11+): $e',
          );
          // We continue anyway, as the path is stored in SharedPreferences
        }

        // Save to SharedPreferences
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_externalLibraryKey, selectedDirectory);

        return selectedDirectory;
      }
      return null;
    } catch (e) {
      debugPrint('ComicService pickLibraryDirectory Error: $e');
      return null;
    }
  }

  static Future<void> deleteComic(Comic comic) async {
    final comics = await loadComics();
    final updatedComics = comics.where((c) => c.id != comic.id).toList();
    await saveComics(updatedComics);

    // Also delete the physical file if it exists in our internal library
    if (comic.localPath != null) {
      final file = File(comic.localPath!);
      if (file.existsSync()) {
        try {
          await file.delete();
          debugPrint('ComicService: Deleted file ${file.path}');
        } catch (e) {
          debugPrint('ComicService: Error deleting file: $e');
        }
      }
    }
  }

  /// Scans library folders and syncs with SharedPreferences
  static Future<List<Comic>> syncWithFolder() async {
    final internalPath = await getLibraryPath();
    final externalPath = await getExternalLibraryPath();

    debugPrint('ComicService: Starting sync...');
    debugPrint('ComicService: Internal path: $internalPath');
    debugPrint('ComicService: External path: $externalPath');

    final existingComics = await loadComics();
    debugPrint('ComicService: Existing comics in DB: ${existingComics.length}');

    List<Comic> updatedList = List.from(existingComics);
    bool changed = false;

    // Scan internal folder
    changed |= await _scanAndAddFromDir(
      internalPath,
      existingComics,
      updatedList,
    );

    // Scan external folder if exists
    if (externalPath != null) {
      final externalDir = Directory(externalPath);
      if (externalDir.existsSync()) {
        changed |= await _scanAndAddFromDir(
          externalPath,
          existingComics,
          updatedList,
        );
      } else {
        debugPrint(
          'ComicService: External library directory not found: $externalPath',
        );
      }
    }

    // Also remove entries from SharedPreferences if file no longer exists
    final List<Comic> finalList = [];
    for (var comic in updatedList) {
      if (comic.localPath != null) {
        final normalizedPath = p.normalize(comic.localPath!);
        if (File(normalizedPath).existsSync()) {
          finalList.add(comic);
        } else {
          changed = true;
          debugPrint(
            'ComicService: File no longer exists, removing from library: ${comic.title} at $normalizedPath',
          );
        }
      } else {
        // Network comics don't have localPath, keep them
        finalList.add(comic);
      }
    }

    if (changed) {
      debugPrint('ComicService: Library changed, saving to SharedPreferences');
      await saveComics(finalList);
    } else {
      debugPrint('ComicService: No changes in library');
    }
    return finalList;
  }

  static Future<bool> _scanAndAddFromDir(
    String dirPath,
    List<Comic> existingComics,
    List<Comic> updatedList,
  ) async {
    bool changed = false;
    try {
      final dir = Directory(dirPath);
      if (!dir.existsSync()) {
        debugPrint('ComicService: Directory does not exist: $dirPath');
        return false;
      }

      debugPrint('ComicService: Scanning directory: $dirPath');
      // Use recursive scan to find comics in subfolders
      final List<FileSystemEntity> entities = dir.listSync(recursive: true);
      debugPrint('ComicService: Found ${entities.length} entities in $dirPath');

      for (var entity in entities) {
        final path = p.normalize(entity.path);
        final fileName = p.basename(path);
        debugPrint(
          'ComicService: Processing entity: $path (isDir: ${entity is Directory})',
        );

        if (entity is File) {
          final extension = p.extension(fileName).toLowerCase();

          if (![
            '.cbz',
            '.cbr',
            '.pdf',
            '.zip',
            '.rar',
            '.tar',
          ].contains(extension)) {
            continue;
          }

          // Check if this file is already in our library (normalize paths for comparison)
          bool alreadyExists = updatedList.any(
            (c) => c.localPath != null && p.normalize(c.localPath!) == path,
          );

          if (!alreadyExists) {
            debugPrint(
              'ComicService: Found new file: $fileName, adding to library...',
            );
            final name = p.basenameWithoutExtension(fileName);
            ComicFileType type = ComicFileType.unknown;
            if (extension == '.cbz' || extension == '.zip') {
              type = ComicFileType.cbz;
            } else if (extension == '.cbr' || extension == '.rar') {
              type = ComicFileType.cbr;
            } else if (extension == '.pdf') {
              type = ComicFileType.pdf;
            }

            Uint8List? thumbnail;
            if (type == ComicFileType.cbz) {
              try {
                thumbnail = await compute(_extractFirstCBZPage, path);
              } catch (e) {
                debugPrint('Thumbnail extraction error during sync: $e');
              }
            }

            updatedList.add(
              Comic(
                // Use a more unique ID to avoid collisions
                id:
                    '${DateTime.now().millisecondsSinceEpoch}_${fileName.hashCode}_${updatedList.length}',
                title: name,
                subtitle: type.toString().split('.').last.toUpperCase(),
                imageUrl: '',
                coverBytes: thumbnail,
                progress: 0.0,
                genre: 'Local File',
                localPath: path,
                source: ComicSource.local,
                fileType: type,
                description: 'Discovered in library folder: $dirPath',
              ),
            );
            changed = true;
          }
        }
      }
    } catch (e) {
      debugPrint('ComicService: Error scanning directory $dirPath: $e');
    }
    return changed;
  }

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

  /// Extracts all image pages from a CBZ file
  static Future<List<Uint8List>> getPagesFromCBZ(String path) async {
    debugPrint('ComicService: Extracting pages from $path');
    return compute(_extractCBZPages, path);
  }

  /// Background isolate function to avoid UI jank
  static List<Uint8List> _extractCBZPages(String path) {
    try {
      final file = File(path);
      if (!file.existsSync()) {
        debugPrint('ComicService: File not found: $path');
        return [];
      }

      final bytes = file.readAsBytesSync();
      debugPrint('ComicService: Read ${bytes.length} bytes');
      final archive = ZipDecoder().decodeBytes(bytes);
      debugPrint(
        'ComicService: Archive decoded, entries: ${archive.files.length}',
      );

      // Filter images and sort
      final imageFiles =
          archive.files.where((f) {
            if (!f.isFile) return false;
            final name = f.name.toLowerCase();
            // Ignore system files
            if (name.contains('__macosx') ||
                name.split('/').last.startsWith('.')) {
              return false;
            }

            final ext = p.extension(name);
            return ['.jpg', '.jpeg', '.png', '.webp', '.gif'].contains(ext);
          }).toList();

      debugPrint('ComicService: Found ${imageFiles.length} image files');
      imageFiles.sort((a, b) => a.name.compareTo(b.name));

      final List<Uint8List> pages = [];
      for (final f in imageFiles) {
        final dynamic content = f.content;
        if (content == null) continue;

        if (content is Uint8List) {
          pages.add(content);
        } else if (content is List<int>) {
          pages.add(Uint8List.fromList(content));
        }
      }

      debugPrint('ComicService: Successfully extracted ${pages.length} pages');
      return pages;
    } catch (e) {
      debugPrint('ComicService: Error extracting CBZ: $e');
      return [];
    }
  }

  static Uint8List? _extractFirstCBZPage(String path) {
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      final bytes = file.readAsBytesSync();
      final archive = ZipDecoder().decodeBytes(bytes);

      final imageFiles =
          archive.files.where((file) {
            if (!file.isFile) return false;
            final ext = p.extension(file.name).toLowerCase();
            return ['.jpg', '.jpeg', '.png', '.webp'].contains(ext);
          }).toList();

      imageFiles.sort((a, b) => a.name.compareTo(b.name));

      if (imageFiles.isNotEmpty) {
        final content = imageFiles.first.content;
        if (content is Uint8List) {
          return content;
        } else if (content is List<int>) {
          return Uint8List.fromList(content);
        }
      }
      return null;
    } catch (e) {
      debugPrint('Error in _extractFirstCBZPage: $e');
      return null;
    }
  }
}
