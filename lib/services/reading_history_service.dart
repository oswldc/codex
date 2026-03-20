import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/comic.dart';

class ReadingHistoryEntry {
  final String id;
  final String title;
  final String subtitle;
  final String? thumbnailPath;
  final int currentPage;
  final int totalPages;
  final int lastRead;

  ReadingHistoryEntry({
    required this.id,
    required this.title,
    required this.subtitle,
    this.thumbnailPath,
    required this.currentPage,
    required this.totalPages,
    required this.lastRead,
  });

  double get progress =>
      totalPages > 0 ? (currentPage / totalPages).clamp(0.0, 1.0) : 0.0;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'subtitle': subtitle,
    'thumbnailPath': thumbnailPath,
    'currentPage': currentPage,
    'totalPages': totalPages,
    'lastRead': lastRead,
  };

  factory ReadingHistoryEntry.fromJson(Map<String, dynamic> json) =>
      ReadingHistoryEntry(
        id: json['id'] as String,
        title: json['title'] as String,
        subtitle: json['subtitle'] as String,
        thumbnailPath: json['thumbnailPath'] as String?,
        currentPage: json['currentPage'] as int,
        totalPages: json['totalPages'] as int,
        lastRead: json['lastRead'] as int,
      );

  /// Buat entry dari Comic model
  factory ReadingHistoryEntry.fromComic(Comic comic) => ReadingHistoryEntry(
    id: comic.id,
    title: comic.title,
    subtitle: comic.subtitle,
    thumbnailPath: comic.thumbnailPath,
    currentPage: comic.currentPage ?? 0,
    totalPages: comic.totalPages ?? 0,
    lastRead: comic.lastRead ?? DateTime.now().millisecondsSinceEpoch,
  );
}

class ReadingHistoryService {
  static const _key = 'reading_history';

  // ─── Load ─────────────────────────────────────────────────────────────────

  static Future<List<ReadingHistoryEntry>> loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return [];

    try {
      final List decoded = jsonDecode(raw) as List;
      final entries =
          decoded
              .map(
                (e) => ReadingHistoryEntry.fromJson(e as Map<String, dynamic>),
              )
              .toList();
      entries.sort((a, b) => b.lastRead.compareTo(a.lastRead));
      return entries;
    } catch (_) {
      return [];
    }
  }

  // ─── Save ─────────────────────────────────────────────────────────────────

  static Future<void> saveEntry(ReadingHistoryEntry entry) async {
    final prefs = await SharedPreferences.getInstance();
    final history = await loadHistory();

    history.removeWhere((e) => e.id == entry.id);
    history.insert(0, entry);

    await prefs.setString(
      _key,
      jsonEncode(history.map((e) => e.toJson()).toList()),
    );
  }

  // ─── Remove ───────────────────────────────────────────────────────────────

  static Future<void> removeEntry(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final history = await loadHistory();
    history.removeWhere((e) => e.id == id);
    await prefs.setString(
      _key,
      jsonEncode(history.map((e) => e.toJson()).toList()),
    );
  }

  // ─── Clear ────────────────────────────────────────────────────────────────

  static Future<void> clearHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  // ─── Migrasi dari ComicService (jalan sekali) ─────────────────────────────

  /// Salin riwayat lama dari library ke ReadingHistoryService.
  /// Dipanggil dari RecentPage saat pertama kali dibuka.
  static Future<void> migrateFromComics(List<Comic> comics) async {
    final prefs = await SharedPreferences.getInstance();
    const migratedKey = 'history_migrated_v1';

    if (prefs.getBool(migratedKey) ?? false) return;

    for (final comic in comics) {
      if (comic.lastRead == null) continue;
      await saveEntry(ReadingHistoryEntry.fromComic(comic));
    }

    await prefs.setBool(migratedKey, true);
  }
}
