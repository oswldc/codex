import 'dart:io';
import 'dart:typed_data';
import 'package:exif/exif.dart';
import 'package:flutter/material.dart';
import '../models/comic.dart';
import '../services/comic_service.dart';
import '../services/reading_history_service.dart';
import 'reader_page.dart';

// ─── EXIF-aware thumbnail ──────────────────────────────────────────────────

class _ExifImage extends StatefulWidget {
  final String path;
  final BoxFit fit;

  const _ExifImage({required this.path, this.fit = BoxFit.cover});

  @override
  State<_ExifImage> createState() => _ExifImageState();
}

class _ExifImageState extends State<_ExifImage> {
  int _quarterTurns = 0;

  @override
  void initState() {
    super.initState();
    _readExif();
  }

  Future<void> _readExif() async {
    try {
      final bytes = await File(widget.path).readAsBytes();
      final tags = await readExifFromBytes(bytes);
      debugPrint('=== EXIF tags for ${widget.path} ===');
      tags.forEach((key, value) => debugPrint('$key: ${value.printable}'));
      final orientation = tags['Image Orientation'];
      if (orientation == null) return;

      // Nilai EXIF orientation → quarterTurns untuk RotatedBox
      // 1 = normal, 3 = 180°, 6 = 90° CW, 8 = 90° CCW
      final raw = orientation.printable;
      int turns = 0;
      if (raw.contains('Rotated 180'))
        turns = 2;
      else if (raw.contains('Rotated 90 CW'))
        turns = 1;
      else if (raw.contains('Rotated 90 CCW'))
        turns = 3;

      if (turns != 0 && mounted) {
        setState(() => _quarterTurns = turns);
      }
    } catch (_) {
      // Gagal baca EXIF → tampil tanpa rotasi, tidak masalah
    }
  }

  @override
  Widget build(BuildContext context) {
    return RotatedBox(
      quarterTurns: _quarterTurns,
      child: Image.file(File(widget.path), fit: widget.fit),
    );
  }
}

// ─── RecentPage ───────────────────────────────────────────────────────────

class RecentPage extends StatefulWidget {
  const RecentPage({super.key});

  @override
  State<RecentPage> createState() => _RecentPageState();
}

class _RecentPageState extends State<RecentPage> with WidgetsBindingObserver {
  List<ReadingHistoryEntry> _history = [];
  Set<String> _libraryIds = {};
  bool _isLoading = true;

  // ─── Lifecycle ────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadAll();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _loadAll();
  }

  // ─── Data ─────────────────────────────────────────────────────────────────

  Future<void> _loadAll() async {
    if (_history.isEmpty) setState(() => _isLoading = true);

    final allComics = await ComicService.loadComics();
    await ReadingHistoryService.migrateFromComics(allComics);
    final history = await ReadingHistoryService.loadHistory();

    if (mounted) {
      setState(() {
        _history = history;
        _libraryIds = allComics.map((c) => c.id).toSet();
        _isLoading = false;
      });
    }
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────

  String _formatRelativeTime(int? timestamp) {
    if (timestamp == null) return '';
    final dateTime = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final diff = DateTime.now().difference(dateTime);

    if (diff.inSeconds < 60) return 'Baru saja';
    if (diff.inMinutes < 60) return '${diff.inMinutes} menit lalu';
    if (diff.inHours < 24) return '${diff.inHours} jam lalu';
    if (diff.inDays == 1) return 'Kemarin';
    if (diff.inDays < 7) return '${diff.inDays} hari lalu';

    return '${dateTime.day}/${dateTime.month}/${dateTime.year}';
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final Color primaryColor = Theme.of(context).primaryColor;
    final Color accentColor = Theme.of(context).colorScheme.secondary;

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_history.isEmpty) {
      return RefreshIndicator(
        onRefresh: _loadAll,
        color: accentColor,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.65,
              child: const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.history, size: 72, color: Colors.white10),
                  SizedBox(height: 16),
                  Text(
                    'Belum ada riwayat baca',
                    style: TextStyle(color: Colors.white38, fontSize: 16),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Tarik ke bawah untuk memperbarui',
                    style: TextStyle(color: Colors.white24, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadAll,
      color: accentColor,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _history.length,
        itemBuilder: (context, index) {
          return _buildHistoryItem(_history[index], primaryColor, accentColor);
        },
      ),
    );
  }

  // ─── Item Card ────────────────────────────────────────────────────────────

  Widget _buildHistoryItem(
    ReadingHistoryEntry entry,
    Color primaryColor,
    Color accentColor,
  ) {
    final bool isDeleted = !_libraryIds.contains(entry.id);
    final bool fileExists =
        entry.thumbnailPath != null && File(entry.thumbnailPath!).existsSync();

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color:
            isDeleted
                ? Colors.white.withValues(alpha: 0.02)
                : primaryColor.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color:
              isDeleted
                  ? Colors.white.withValues(alpha: 0.03)
                  : Colors.white.withValues(alpha: 0.05),
        ),
      ),
      child: InkWell(
        onTap: () async {
          if (isDeleted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text(
                  'File komik tidak ditemukan di library',
                  style: TextStyle(color: Colors.white),
                ),
                backgroundColor: const Color(0xFF4B5BAB),
                behavior: SnackBarBehavior.floating,
                action: SnackBarAction(
                  label: 'Hapus Riwayat',
                  textColor: Colors.red,
                  onPressed: () async {
                    await ReadingHistoryService.removeEntry(entry.id);
                    _loadAll();
                  },
                ),
              ),
            );
            return;
          }

          final allComics = await ComicService.loadComics();
          final Comic? comic =
              allComics.where((c) => c.id == entry.id).firstOrNull;
          if (!mounted || comic == null) return;

          await Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => ReaderPage(comic: comic)),
          );
          _loadAll();
        },
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              // ── Cover ───────────────────────────────────────────────────
              Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 60,
                      height: 90,
                      child:
                          fileExists
                              ? ColorFiltered(
                                colorFilter:
                                    isDeleted
                                        ? const ColorFilter.matrix([
                                          0.2126,
                                          0.7152,
                                          0.0722,
                                          0,
                                          0,
                                          0.2126,
                                          0.7152,
                                          0.0722,
                                          0,
                                          0,
                                          0.2126,
                                          0.7152,
                                          0.0722,
                                          0,
                                          0,
                                          0,
                                          0,
                                          0,
                                          1,
                                          0,
                                        ])
                                        : const ColorFilter.mode(
                                          Colors.transparent,
                                          BlendMode.multiply,
                                        ),
                                // ✅ Pakai _ExifImage agar rotasi EXIF diterapkan
                                child: _ExifImage(
                                  path: entry.thumbnailPath!,
                                  fit: BoxFit.cover,
                                ),
                              )
                              : Container(
                                color: Colors.white10,
                                child: const Icon(
                                  Icons.book,
                                  color: Colors.white24,
                                ),
                              ),
                    ),
                  ),
                  if (isDeleted)
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.red.shade900.withValues(alpha: 0.85),
                          borderRadius: const BorderRadius.only(
                            bottomLeft: Radius.circular(8),
                            bottomRight: Radius.circular(8),
                          ),
                        ),
                        child: const Text(
                          'Dihapus',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 9, color: Colors.white70),
                        ),
                      ),
                    ),
                ],
              ),

              const SizedBox(width: 16),

              // ── Info ────────────────────────────────────────────────────
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.title,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: isDeleted ? Colors.white38 : null,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      entry.subtitle,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.white38,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(
                          Icons.access_time_rounded,
                          size: 11,
                          color: accentColor.withValues(alpha: 0.6),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _formatRelativeTime(entry.lastRead),
                          style: TextStyle(
                            fontSize: 11,
                            color: accentColor.withValues(alpha: 0.6),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Hal. ${entry.currentPage} / ${entry.totalPages}',
                          style: TextStyle(
                            fontSize: 12,
                            color:
                                isDeleted
                                    ? Colors.white24
                                    : accentColor.withValues(alpha: 0.85),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          '${(entry.progress * 100).toInt()}%',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.white38,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Container(
                      height: 4,
                      clipBehavior: Clip.hardEdge,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(4),
                        color: Colors.white10,
                      ),
                      child: LinearProgressIndicator(
                        value: entry.progress,
                        backgroundColor: Colors.transparent,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          isDeleted ? Colors.white24 : accentColor,
                        ),
                        minHeight: 4,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 8),
              Icon(
                isDeleted ? Icons.block : Icons.chevron_right,
                color: Colors.white24,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
