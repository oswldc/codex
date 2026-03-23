import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/comic.dart';
import '../services/comic_service.dart';
import 'reader_page.dart';

/// Pengganti ComicDetailPage lama.
/// Tetap menerima [Comic] sebagai parameter agar semua pemanggil lama
/// (library_page, recent_page, dll) tidak perlu diubah.
/// Di dalamnya, Comic di-convert ke ComicSeries lalu ditampilkan
/// dengan tampilan series + daftar semua volume.
class ComicDetailPage extends StatefulWidget {
  final Comic comic;

  const ComicDetailPage({super.key, required this.comic});

  @override
  State<ComicDetailPage> createState() => _ComicDetailPageState();
}

class _ComicDetailPageState extends State<ComicDetailPage> {
  late ComicSeries _currentSeries;

  @override
  void initState() {
    super.initState();
    _currentSeries = _seriesFromComic(widget.comic);
    _refreshSeries();
  }

  /// Buat ComicSeries sementara dari satu Comic (untuk inisialisasi awal)
  ComicSeries _seriesFromComic(Comic comic) {
    return ComicSeries(seriesTitle: comic.seriesTitle, volumes: [comic]);
  }

  Future<void> _refreshSeries() async {
    final comics = await ComicService.loadComics();
    final allSeries = ComicService.groupBySeries(comics);
    final updated = allSeries.firstWhere(
      (s) => s.seriesTitle == _currentSeries.seriesTitle,
      orElse: () => _currentSeries,
    );
    if (mounted) {
      setState(() => _currentSeries = updated);
    }
  }

  Future<void> _openVolume(Comic comic) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => ReaderPage(comic: comic)),
    );
    _refreshSeries();
  }

  Future<void> _deleteVolume(Comic comic) async {
    final result = await showDialog<String>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Hapus Volume'),
            content: Text(
              'Apa yang ingin kamu lakukan dengan "${comic.title}"?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, 'cancel'),
                child: const Text('Batal'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, 'library'),
                child: const Text('Hapus dari library'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, 'delete'),
                child: const Text(
                  'Hapus file',
                  style: TextStyle(color: Colors.redAccent),
                ),
              ),
            ],
          ),
    );

    if (result == null || result == 'cancel') return;
    await ComicService.deleteComic(comic, deleteFile: result == 'delete');
    await _refreshSeries();

    // Kalau semua volume sudah dihapus, kembali ke library
    if (_currentSeries.volumes.isEmpty && mounted) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final Color primaryColor = Theme.of(context).primaryColor;
    final representative = _currentSeries.representative;
    final isSingleVolume = _currentSeries.volumeCount == 1;

    return Scaffold(
      body: Stack(
        children: [
          // ─── Background blurred cover ──────────────────────────────────
          SizedBox(
            height: MediaQuery.of(context).size.height * 0.5,
            width: double.infinity,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _buildCoverImage(representative, fit: BoxFit.cover),
                BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.3),
                          Theme.of(context).scaffoldBackgroundColor,
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ─── Scrollable content ────────────────────────────────────────
          CustomScrollView(
            slivers: [
              // Cover besar di tengah
              SliverToBoxAdapter(
                child: SizedBox(
                  height: MediaQuery.of(context).size.height * 0.28,
                  child: Center(
                    child: Container(
                      margin: const EdgeInsets.only(top: 80),
                      width: 150,
                      height: 220,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.6),
                            blurRadius: 24,
                            offset: const Offset(0, 12),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: _buildCoverImage(representative),
                      ),
                    ),
                  ),
                ),
              ),

              // Info series
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _currentSeries.seriesTitle,
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          height: 1.1,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          _buildStatChip(
                            icon: Icons.library_books,
                            label:
                                isSingleVolume
                                    ? '1 volume'
                                    : '${_currentSeries.volumeCount} volumes',
                            color: primaryColor,
                          ),
                          const SizedBox(width: 10),
                          _buildStatChip(
                            icon: Icons.history,
                            label:
                                _currentSeries.averageProgress > 0
                                    ? '${(_currentSeries.averageProgress * 100).toInt()}% dibaca'
                                    : 'Belum dibaca',
                            color: Colors.white24,
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Text(
                            isSingleVolume ? 'Detail' : 'Semua Volume',
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (!isSingleVolume)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: primaryColor.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                '${_currentSeries.volumeCount}',
                                style: TextStyle(
                                  color: primaryColor,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                    ],
                  ),
                ),
              ),

              // ─── Daftar volume ───────────────────────────────────────────
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 120),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final comic = _currentSeries.volumes[index];
                    return _VolumeCard(
                      comic: comic,
                      volumeIndex: index,
                      primaryColor: primaryColor,
                      onTap: () => _openVolume(comic),
                      onDelete: () => _deleteVolume(comic),
                    );
                  }, childCount: _currentSeries.volumes.length),
                ),
              ),
            ],
          ),

          // ─── App bar icons ─────────────────────────────────────────────
          Positioned(
            top: 48,
            left: 16,
            right: 16,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _buildCircleButton(
                  Icons.arrow_back,
                  () => Navigator.pop(context),
                ),
                _buildCircleButton(Icons.more_horiz, () {}),
              ],
            ),
          ),

          // ─── Bottom CTA ────────────────────────────────────────────────
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Theme.of(
                      context,
                    ).scaffoldBackgroundColor.withValues(alpha: 0),
                    Theme.of(
                      context,
                    ).scaffoldBackgroundColor.withValues(alpha: 0.95),
                    Theme.of(context).scaffoldBackgroundColor,
                  ],
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    height: 4,
                    clipBehavior: Clip.hardEdge,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      color: Colors.white10,
                    ),
                    child: LinearProgressIndicator(
                      value: _currentSeries.averageProgress,
                      backgroundColor: Colors.transparent,
                      valueColor: AlwaysStoppedAnimation(primaryColor),
                      minHeight: 4,
                    ),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () => _openVolume(_nextVolumeToRead()),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: primaryColor,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(double.infinity, 56),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 8,
                      shadowColor: primaryColor.withValues(alpha: 0.4),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.menu_book),
                        const SizedBox(width: 8),
                        Text(
                          _ctaLabel(),
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────

  Comic _nextVolumeToRead() {
    final inProgress = _currentSeries.volumes.where(
      (v) => v.progress > 0 && v.progress < 1.0,
    );
    if (inProgress.isNotEmpty) return inProgress.first;

    final unread = _currentSeries.volumes.where((v) => v.progress == 0);
    if (unread.isNotEmpty) return unread.first;

    return _currentSeries.volumes.first;
  }

  String _ctaLabel() {
    final next = _nextVolumeToRead();
    final volLabel =
        next.volumeNumber != null ? ' Volume ${next.volumeNumber}' : '';

    if (next.progress > 0 && next.progress < 1.0) return 'Lanjut Baca$volLabel';
    if (_currentSeries.averageProgress == 0) return 'Mulai Baca$volLabel';
    return 'Baca Lagi$volLabel';
  }

  Widget _buildStatChip({
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(color: color, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildCircleButton(IconData icon, VoidCallback onPressed) {
    return ClipOval(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          color: Colors.black.withValues(alpha: 0.4),
          child: IconButton(
            icon: Icon(icon, color: Colors.white, size: 20),
            onPressed: onPressed,
          ),
        ),
      ),
    );
  }

  Widget _buildCoverImage(Comic comic, {BoxFit fit = BoxFit.cover}) {
    if (comic.source == ComicSource.local && comic.thumbnailPath != null) {
      final file = File(comic.thumbnailPath!);
      if (file.existsSync()) return Image.file(file, fit: fit);
    }
    if (comic.coverBytes != null) {
      return Image.memory(comic.coverBytes!, fit: fit);
    }
    if (comic.imageUrl.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: comic.imageUrl,
        fit: fit,
        placeholder:
            (context, url) => Container(
              color: Colors.white10,
              child: const Center(child: CircularProgressIndicator()),
            ),
        errorWidget: (context, url, error) => const Icon(Icons.error),
      );
    }
    return Container(
      color: Colors.white10,
      child: const Icon(Icons.book, size: 48),
    );
  }
}

// ─── Volume Card ──────────────────────────────────────────────────────────────

class _VolumeCard extends StatelessWidget {
  final Comic comic;
  final int volumeIndex;
  final Color primaryColor;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _VolumeCard({
    required this.comic,
    required this.volumeIndex,
    required this.primaryColor,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final volLabel =
        comic.volumeNumber != null
            ? 'Volume ${comic.volumeNumber}'
            : 'Volume ${volumeIndex + 1}';
    final isDone = comic.progress >= 1.0;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          height: 96,
          decoration: BoxDecoration(
            color: primaryColor.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color:
                  isDone ? Colors.green.withValues(alpha: 0.3) : Colors.white10,
              width: 0.8,
            ),
          ),
          child: Row(
            children: [
              // Thumbnail
              ClipRRect(
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(14),
                  bottomLeft: Radius.circular(14),
                ),
                child: SizedBox(width: 64, height: 96, child: _buildCover()),
              ),

              // Info
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Text(
                            volLabel,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: isDone ? Colors.green : Colors.white,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white10,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              comic.fileType
                                  .toString()
                                  .split('.')
                                  .last
                                  .toUpperCase(),
                              style: const TextStyle(
                                color: Colors.white38,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: comic.progress.clamp(0.0, 1.0),
                              minHeight: 3,
                              backgroundColor: Colors.white12,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                isDone ? Colors.green : primaryColor,
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            isDone
                                ? 'Selesai'
                                : comic.progress > 0
                                ? '${(comic.progress * 100).toInt()}%${comic.currentPage != null ? ' • halaman ${comic.currentPage}' : ''}'
                                : 'Belum dibaca',
                            style: TextStyle(
                              fontSize: 11,
                              color: isDone ? Colors.green : Colors.white38,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              // Aksi
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    GestureDetector(
                      onTap: onTap,
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: primaryColor.withValues(alpha: 0.2),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.play_arrow_rounded,
                          size: 20,
                          color: primaryColor,
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: onDelete,
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Colors.black26,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white10),
                        ),
                        child: const Icon(
                          Icons.delete_outline,
                          size: 15,
                          color: Colors.redAccent,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCover() {
    if (comic.source == ComicSource.local && comic.thumbnailPath != null) {
      final file = File(comic.thumbnailPath!);
      if (file.existsSync()) return Image.file(file, fit: BoxFit.cover);
    }
    if (comic.imageUrl.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: comic.imageUrl,
        fit: BoxFit.cover,
        placeholder: (context, url) => Container(color: Colors.white10),
        errorWidget: (context, url, error) => _placeholder(),
      );
    }
    return _placeholder();
  }

  Widget _placeholder() {
    return Container(
      color: Colors.white10,
      child: const Center(
        child: Icon(Icons.book, size: 24, color: Colors.white24),
      ),
    );
  }
}
