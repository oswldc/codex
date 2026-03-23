import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/comic.dart';
import '../services/comic_service.dart';
import 'reader_page.dart';

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
    if (mounted) setState(() => _currentSeries = updated);
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

    if (_currentSeries.volumes.isEmpty && mounted) Navigator.pop(context);
  }

  // ─── Popup menu ───────────────────────────────────────────────────────────

  Widget _buildPopupMenu(BuildContext context) {
    return PopupMenuButton<String>(
      icon: Container(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.4),
          shape: BoxShape.circle,
        ),
        padding: const EdgeInsets.all(8),
        child: const Icon(Icons.more_horiz, color: Colors.white, size: 20),
      ),
      color: const Color(0xFF1E2340),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
      ),
      offset: const Offset(0, 48),
      onSelected: (value) async {
        switch (value) {
          case 'edit':
            _showEditTitleDialog(context);
            break;
          case 'mark_done':
            await _markAllAs(1.0);
            break;
          case 'mark_unread':
            await _markAllAs(0.0);
            break;
          case 'delete':
            await _confirmDeleteSeries(context);
            break;
        }
      },
      itemBuilder:
          (ctx) => [
            PopupMenuItem(
              value: 'edit',
              child: _popupItem(
                Icons.edit_outlined,
                'Edit judul series',
                Colors.white,
              ),
            ),
            PopupMenuItem(
              value: 'mark_done',
              child: _popupItem(
                Icons.check_circle_outline,
                'Tandai semua selesai',
                const Color(0xFFCFFF70),
              ),
            ),
            PopupMenuItem(
              value: 'mark_unread',
              child: _popupItem(
                Icons.radio_button_unchecked,
                'Tandai belum dibaca',
                Colors.white70,
              ),
            ),
            const PopupMenuDivider(),
            PopupMenuItem(
              value: 'delete',
              child: _popupItem(
                Icons.delete_outline,
                'Hapus series',
                Colors.redAccent,
              ),
            ),
          ],
    );
  }

  Widget _popupItem(IconData icon, String label, Color color) {
    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 12),
        Text(label, style: TextStyle(fontSize: 14, color: color)),
      ],
    );
  }

  // ─── Edit judul series ────────────────────────────────────────────────────

  void _showEditTitleDialog(BuildContext context) {
    final controller = TextEditingController(text: _currentSeries.seriesTitle);
    showDialog(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Edit Judul Series'),
            content: TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(hintText: 'Judul series'),
              textCapitalization: TextCapitalization.words,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Batal'),
              ),
              TextButton(
                onPressed: () async {
                  final newTitle = controller.text.trim();
                  if (newTitle.isEmpty ||
                      newTitle == _currentSeries.seriesTitle) {
                    Navigator.pop(ctx);
                    return;
                  }
                  Navigator.pop(ctx);
                  await _renameSeriesTitle(newTitle);
                },
                child: const Text('Simpan'),
              ),
            ],
          ),
    );
  }

  Future<void> _renameSeriesTitle(String newTitle) async {
    final comics = await ComicService.loadComics();
    final updated =
        comics.map((c) {
          if (c.seriesTitle == _currentSeries.seriesTitle) {
            return Comic(
              id: c.id,
              title: c.title,
              subtitle: c.subtitle,
              imageUrl: c.imageUrl,
              coverBytes: c.coverBytes,
              thumbnailPath: c.thumbnailPath,
              progress: c.progress,
              genre: c.genre,
              publisher: c.publisher,
              releaseYear: c.releaseYear,
              writer: c.writer,
              artist: c.artist,
              description: c.description,
              pages: c.pages,
              localPath: c.localPath,
              source: c.source,
              fileType: c.fileType,
              lastRead: c.lastRead,
              currentPage: c.currentPage,
              totalPages: c.totalPages,
              seriesTitle: newTitle,
              volumeNumber: c.volumeNumber,
            );
          }
          return c;
        }).toList();
    await ComicService.saveComics(updated);
    await _refreshSeries();
  }

  // ─── Tandai progress semua volume ─────────────────────────────────────────

  Future<void> _markAllAs(double progress) async {
    for (final comic in _currentSeries.volumes) {
      await ComicService.updateComicProgress(
        comic.id,
        progress,
        currentPage: progress == 0.0 ? 0 : comic.totalPages,
        totalPages: comic.totalPages,
      );
    }
    await _refreshSeries();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            progress >= 1.0
                ? 'Semua volume ditandai selesai'
                : 'Semua volume ditandai belum dibaca',
            style: const TextStyle(color: Colors.white),
          ),
          backgroundColor:
              progress >= 1.0
                  ? Theme.of(context).primaryColor
                  : Colors.blueGrey,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  // ─── Hapus series ──────────────────────────────────────────────────────────

  Future<void> _confirmDeleteSeries(BuildContext context) async {
    final result = await showDialog<String>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Hapus Series'),
            content: Text(
              'Hapus "${_currentSeries.seriesTitle}" beserta '
              '${_currentSeries.volumeCount} volume?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, 'cancel'),
                child: const Text('Batal'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, 'library'),
                child: const Text('Hapus dari library'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, 'delete'),
                child: const Text(
                  'Hapus file',
                  style: TextStyle(color: Colors.redAccent),
                ),
              ),
            ],
          ),
    );

    if (result == null || result == 'cancel') return;
    await ComicService.deleteSeries(
      _currentSeries,
      deleteFiles: result == 'delete',
    );
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final Color primaryColor = Theme.of(context).primaryColor;
    final representative = _currentSeries.representative;
    final isSingleVolume = _currentSeries.volumeCount == 1;

    return Scaffold(
      body: Stack(
        children: [
          // ─── Scrollable content ──────────────────────────────────────────
          RefreshIndicator(
            onRefresh: _refreshSeries,
            child: CustomScrollView(
              slivers: [
                // ─── Header ───────────────────────────────────────────────
                SliverToBoxAdapter(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          primaryColor.withValues(alpha: 0.22),
                          primaryColor.withValues(alpha: 0.0),
                        ],
                        stops: const [0.0, 0.4],
                      ),
                    ),
                    child: Column(
                      children: [
                        const SizedBox(height: 80),

                        // Cover di tengah
                        Center(
                          child: Container(
                            width: 150,
                            height: 150 / 0.65,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.5),
                                  blurRadius: 16,
                                  offset: const Offset(0, 8),
                                ),
                              ],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: _buildCoverImage(representative),
                            ),
                          ),
                        ),

                        const SizedBox(height: 12),

                        // Info di bawah cover, rata tengah
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Text(
                                _currentSeries.seriesTitle,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.bold,
                                  height: 1.2,
                                ),
                              ),
                              if (representative.writer != null) ...[
                                const SizedBox(height: 5),
                                Text(
                                  representative.writer!,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: primaryColor.withValues(alpha: 0.85),
                                  ),
                                ),
                              ],
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                alignment: WrapAlignment.center,
                                children: [
                                  _buildChip(
                                    representative.fileType
                                        .toString()
                                        .split('.')
                                        .last
                                        .toUpperCase(),
                                    primaryColor,
                                  ),
                                  _buildChip('LOCAL', Colors.white24),
                                  if (representative.genre.isNotEmpty &&
                                      representative.genre != 'Local File')
                                    _buildChip(
                                      representative.genre,
                                      Colors.white24,
                                    ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.auto_stories,
                                    size: 13,
                                    color: primaryColor,
                                  ),
                                  const SizedBox(width: 5),
                                  Text(
                                    _currentSeries.averageProgress > 0
                                        ? '${(_currentSeries.averageProgress * 100).toInt()}% dibaca'
                                        : 'Belum dibaca',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.white54,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 16),
                      ],
                    ),
                  ),
                ),

                // ─── Metadata grid ─────────────────────────────────────────
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 0),
                    child: _buildMetaGrid(representative, primaryColor),
                  ),
                ),

                // ─── Section header daftar volume ──────────────────────────
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
                    child: Row(
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
                  ),
                ),

                // ─── Daftar volume ─────────────────────────────────────────
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
          ),

          // ─── App bar icons ───────────────────────────────────────────────
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
                _buildPopupMenu(context),
              ],
            ),
          ),

          // ─── Bottom CTA ──────────────────────────────────────────────────
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

  // ─── Metadata grid ────────────────────────────────────────────────────────

  Widget _buildMetaGrid(Comic comic, Color primaryColor) {
    final items = <_MetaItem>[];

    items.add(
      _MetaItem(
        icon: Icons.folder_zip_outlined,
        label: 'Format',
        value: comic.fileType.toString().split('.').last.toUpperCase(),
      ),
    );

    items.add(
      _MetaItem(
        icon: Icons.library_books_outlined,
        label: 'Volume',
        value: '${_currentSeries.volumeCount} vol',
      ),
    );

    if (_currentSeries.lastRead != null) {
      final date = DateTime.fromMillisecondsSinceEpoch(
        _currentSeries.lastRead!,
      );
      final diff = DateTime.now().difference(date);
      final String timeAgo;
      if (diff.inMinutes < 60) {
        timeAgo = '${diff.inMinutes}m lalu';
      } else if (diff.inHours < 24) {
        timeAgo = '${diff.inHours}j lalu';
      } else if (diff.inDays < 7) {
        timeAgo = '${diff.inDays}h lalu';
      } else {
        timeAgo = '${date.day}/${date.month}/${date.year}';
      }
      items.add(
        _MetaItem(icon: Icons.history, label: 'Terakhir', value: timeAgo),
      );
    }

    if (comic.releaseYear != null) {
      items.add(
        _MetaItem(
          icon: Icons.calendar_today_outlined,
          label: 'Tahun',
          value: comic.releaseYear!,
        ),
      );
    }

    if (comic.artist != null) {
      items.add(
        _MetaItem(
          icon: Icons.brush_outlined,
          label: 'Artist',
          value: comic.artist!,
        ),
      );
    }

    if (comic.publisher != null) {
      items.add(
        _MetaItem(
          icon: Icons.business_outlined,
          label: 'Publisher',
          value: comic.publisher!,
        ),
      );
    }

    if (items.isEmpty) return const SizedBox.shrink();

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 1.6,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: primaryColor.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: primaryColor.withValues(alpha: 0.12),
              width: 0.8,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(item.icon, size: 11, color: Colors.white38),
                  const SizedBox(width: 4),
                  Text(
                    item.label.toUpperCase(),
                    style: const TextStyle(
                      fontSize: 9,
                      color: Colors.white38,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
              Text(
                item.value,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        );
      },
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

  Widget _buildChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color == Colors.white24 ? Colors.white54 : color,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildCircleButton(IconData icon, VoidCallback onPressed) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.4),
        shape: BoxShape.circle,
      ),
      child: IconButton(
        icon: Icon(icon, color: Colors.white, size: 20),
        onPressed: onPressed,
      ),
    );
  }

  Widget _buildCoverImage(Comic comic, {BoxFit fit = BoxFit.cover}) {
    if (comic.source == ComicSource.local && comic.thumbnailPath != null) {
      final file = File(comic.thumbnailPath!);
      if (file.existsSync()) return Image.file(file, fit: fit);
    }
    if (comic.coverBytes != null)
      return Image.memory(comic.coverBytes!, fit: fit);
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

// ─── Helper data class ────────────────────────────────────────────────────────

class _MetaItem {
  final IconData icon;
  final String label;
  final String value;
  const _MetaItem({
    required this.icon,
    required this.label,
    required this.value,
  });
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

    String? fileSize;
    if (comic.localPath != null) {
      final file = File(comic.localPath!);
      if (file.existsSync()) {
        final bytes = file.lengthSync();
        fileSize =
            bytes >= 1024 * 1024 * 1024
                ? '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB'
                : bytes >= 1024 * 1024
                ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB'
                : '${(bytes / 1024).toStringAsFixed(0)} KB';
      }
    }

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
                  isDone
                      ? const Color(0xFFCFFF70).withValues(alpha: 0.3)
                      : Colors.white10,
              width: 0.8,
            ),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(14),
                  bottomLeft: Radius.circular(14),
                ),
                child: SizedBox(width: 64, height: 96, child: _buildCover()),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
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
                              color:
                                  isDone
                                      ? const Color(0xFFCFFF70)
                                      : Colors.white,
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
                      Row(
                        children: [
                          if (comic.totalPages != null &&
                              comic.totalPages! > 0) ...[
                            const Icon(
                              Icons.menu_book_outlined,
                              size: 11,
                              color: Colors.white38,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              '${comic.totalPages} hal',
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.white38,
                              ),
                            ),
                            const SizedBox(width: 10),
                          ],
                          if (fileSize != null) ...[
                            const Icon(
                              Icons.storage_outlined,
                              size: 11,
                              color: Colors.white38,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              fileSize,
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.white38,
                              ),
                            ),
                          ],
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
                                isDone ? const Color(0xFFCFFF70) : primaryColor,
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
                              color:
                                  isDone
                                      ? const Color(0xFFCFFF70)
                                      : Colors.white38,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
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
