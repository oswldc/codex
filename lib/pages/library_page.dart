import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/comic.dart';
import '../services/comic_service.dart';
import 'comic_detail_page.dart';
import 'recent_page.dart';

enum ViewMode { grid, gridSmall, list }

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  int _selectedIndex = 0;
  final List<Comic> _allComics = [];

  List<ComicSeries> _allSeries = [];
  List<ComicSeries> _filteredSeries = [];

  bool _isLoading = false;
  ViewMode _viewMode = ViewMode.grid;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _loadSavedComics();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    final query = _searchController.text.trim().toLowerCase();
    setState(() {
      _filteredSeries =
          query.isEmpty
              ? List.from(_allSeries)
              : _allSeries.where((s) {
                return s.seriesTitle.toLowerCase().contains(query);
              }).toList();
    });
  }

  // ─── Core fetch ───────────────────────────────────────────────────────────

  Future<void> _fetchComics() async {
    final comics = await ComicService.syncWithFolder();
    if (mounted) {
      setState(() {
        _allComics
          ..clear()
          ..addAll(comics);
        _allSeries = ComicService.groupBySeries(_allComics);
        _filteredSeries = List.from(_allSeries);
        if (_searchController.text.trim().isNotEmpty) _onSearchChanged();
      });
    }
  }

  // ─── Load dengan spinner ──────────────────────────────────────────────────

  Future<void> _loadSavedComics() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);
    try {
      await _fetchComics();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Gagal memuat library: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ─── Delete series ────────────────────────────────────────────────────────

  Future<void> _deleteSeries(ComicSeries series) async {
    final isSingle = series.volumeCount == 1;
    final result = await showDialog<String>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: Text(isSingle ? 'Hapus Komik' : 'Hapus Series'),
            content: Text(
              isSingle
                  ? 'Apa yang ingin kamu lakukan dengan "${series.seriesTitle}"?'
                  : 'Hapus semua ${series.volumeCount} volume "${series.seriesTitle}"?',
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
    await ComicService.deleteSeries(series, deleteFiles: result == 'delete');
    await _loadSavedComics();
  }

  // ─── Add komik ────────────────────────────────────────────────────────────

  Future<void> _addLocalComics() async {
    try {
      final newComics = await ComicService.pickAndParseComics();

      if (!mounted) return;

      if (newComics.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Tidak ada komik baru yang ditambahkan'),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }

      setState(() => _isLoading = true);
      try {
        await _fetchComics();
      } finally {
        if (mounted) setState(() => _isLoading = false);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${newComics.length} komik ditambahkan'),
            backgroundColor: Theme.of(context).primaryColor,
          ),
        );
      }
    } catch (e) {
      debugPrint('_addLocalComics error: $e');
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  // ─── Navigate ke detail series ────────────────────────────────────────────

  Future<void> _openSeries(ComicSeries series) async {
    _searchFocusNode.unfocus();
    FocusScope.of(context).unfocus();
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ComicDetailPage(comic: series.representative),
      ),
    );
    await _loadSavedComics();
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final Color primaryColor = Theme.of(context).primaryColor;
    final Color accentColor = Theme.of(context).colorScheme.secondary;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(context, primaryColor),
            Expanded(
              child: IndexedStack(
                index: _selectedIndex,
                children: [
                  _buildLibraryTab(context, accentColor),
                  const RecentPage(),
                  const Center(child: Text('Settings Coming Soon')),
                ],
              ),
            ),
          ],
        ),
      ),
      floatingActionButton:
          _selectedIndex == 0
              ? FloatingActionButton(
                onPressed: _addLocalComics,
                backgroundColor: primaryColor,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30),
                ),
                child: const Icon(Icons.add, size: 32, color: Colors.white),
              )
              : null,
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: primaryColor.withValues(alpha: 0.2),
              width: 0.5,
            ),
          ),
        ),
        child: Theme(
          data: Theme.of(context).copyWith(splashColor: Colors.transparent),
          child: BottomNavigationBar(
            currentIndex: _selectedIndex,
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            selectedItemColor: accentColor,
            unselectedItemColor: Colors.white38,
            onTap: (index) => setState(() => _selectedIndex = index),
            items: const [
              BottomNavigationBarItem(
                icon: Icon(Icons.auto_stories),
                label: 'Library',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.history),
                label: 'Recent',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.settings),
                label: 'Settings',
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Header ───────────────────────────────────────────────────────────────

  Widget _buildHeader(BuildContext context, Color primaryColor) {
    final titles = ['Codex Library', 'Recent Reads', 'Settings'];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(
          bottom: BorderSide(
            color: primaryColor.withValues(alpha: 0.1),
            width: 1,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      titles[_selectedIndex],
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        letterSpacing: -0.5,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (_selectedIndex == 0 && _allSeries.isNotEmpty)
                      Text(
                        '${_allSeries.length} series · ${_allComics.length} volume',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white38,
                        ),
                      ),
                  ],
                ),
              ),
              if (_isLoading)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              if (_selectedIndex == 0)
                IconButton(
                  onPressed: () {
                    setState(() {
                      _viewMode = switch (_viewMode) {
                        ViewMode.grid => ViewMode.gridSmall,
                        ViewMode.gridSmall => ViewMode.list,
                        ViewMode.list => ViewMode.grid,
                      };
                    });
                  },
                  icon: Icon(switch (_viewMode) {
                    ViewMode.grid => Icons.grid_on_rounded,
                    ViewMode.gridSmall => Icons.view_list_rounded,
                    ViewMode.list => Icons.grid_view_rounded,
                  }, color: Colors.white70),
                  tooltip: switch (_viewMode) {
                    ViewMode.grid => 'Beralih ke grid kecil',
                    ViewMode.gridSmall => 'Beralih ke list',
                    ViewMode.list => 'Beralih ke grid besar',
                  },
                ),
            ],
          ),
          if (_selectedIndex == 0) ...[
            const SizedBox(height: 16),
            TextField(
              controller: _searchController,
              focusNode: _searchFocusNode,
              decoration: InputDecoration(
                hintText: 'Cari komik...',
                prefixIcon: const Icon(Icons.search, color: Colors.white38),
                suffixIcon:
                    _searchController.text.isNotEmpty
                        ? IconButton(
                          icon: const Icon(Icons.clear, color: Colors.white38),
                          onPressed: () {
                            _searchController.clear();
                            _onSearchChanged();
                          },
                        )
                        : null,
                filled: true,
                fillColor: primaryColor.withValues(alpha: 0.1),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ─── Library Tab ──────────────────────────────────────────────────────────

  Widget _buildLibraryTab(BuildContext context, Color accentColor) {
    if (!_isLoading && _allSeries.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.menu_book, size: 128, color: Colors.white10),
            const SizedBox(height: 12),
            const Text(
              'Library kosong',
              style: TextStyle(color: Colors.white38, fontSize: 16),
            ),
            const SizedBox(height: 4),
            const Text(
              'Tekan + untuk menambah komik',
              style: TextStyle(color: Colors.white24, fontSize: 13),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _addLocalComics,
              icon: const Icon(Icons.add),
              label: const Text('Tambah Komik'),
              style: ElevatedButton.styleFrom(
                backgroundColor: accentColor,
                foregroundColor: Theme.of(context).colorScheme.onSecondary,
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
                shape: const StadiumBorder(),
              ),
            ),
          ],
        ),
      );
    }

    if (!_isLoading && _filteredSeries.isEmpty && _allSeries.isNotEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.search_off, size: 64, color: Colors.white24),
            const SizedBox(height: 12),
            Text(
              'Tidak ada hasil untuk "${_searchController.text}"',
              style: const TextStyle(color: Colors.white38),
            ),
          ],
        ),
      );
    }

    return GestureDetector(
      onTap: () => _searchFocusNode.unfocus(),
      behavior: HitTestBehavior.translucent,
      child: RefreshIndicator(
        onRefresh: _loadSavedComics,
        child: switch (_viewMode) {
          ViewMode.grid => _buildGridView(context, crossAxisCount: 2),
          ViewMode.gridSmall => _buildGridView(context, crossAxisCount: 3),
          ViewMode.list => _buildListView(context),
        },
      ),
    );
  }

  // ─── Grid View ────────────────────────────────────────────────────────────

  Widget _buildGridView(BuildContext context, {int crossAxisCount = 2}) {
    final isSmall = crossAxisCount >= 3;
    return GridView.builder(
      padding: EdgeInsets.all(isSmall ? 12 : 16),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        childAspectRatio: isSmall ? 0.55 : 0.6,
        crossAxisSpacing: isSmall ? 10 : 16,
        mainAxisSpacing: isSmall ? 16 : 24,
      ),
      itemCount: _filteredSeries.length,
      itemBuilder: (context, index) {
        final series = _filteredSeries[index];
        return SeriesCard(
          series: series,
          isSmall: isSmall,
          onTap: () => _openSeries(series),
          onDelete: () => _deleteSeries(series),
        );
      },
    );
  }

  // ─── List View ────────────────────────────────────────────────────────────

  Widget _buildListView(BuildContext context) {
    final Color primaryColor = Theme.of(context).primaryColor;

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: _filteredSeries.length,
      itemBuilder: (context, index) {
        final series = _filteredSeries[index];
        return SeriesListTile(
          series: series,
          primaryColor: primaryColor,
          onTap: () => _openSeries(series),
          onDelete: () => _deleteSeries(series),
        );
      },
    );
  }
}

// ─── Series Card (Grid) ───────────────────────────────────────────────────────

class SeriesCard extends StatelessWidget {
  final ComicSeries series;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final bool isSmall;

  const SeriesCard({
    super.key,
    required this.series,
    required this.onTap,
    required this.onDelete,
    this.isSmall = false,
  });

  @override
  Widget build(BuildContext context) {
    final Color primaryColor = Theme.of(context).primaryColor;
    final comic = series.representative;

    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.5),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _buildCover(comic),

                    // Progress bar bawah
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: Container(
                        height: 4,
                        color: Colors.black45,
                        child: FractionallySizedBox(
                          alignment: Alignment.centerLeft,
                          widthFactor: series.averageProgress.clamp(0.0, 1.0),
                          child: Container(color: primaryColor),
                        ),
                      ),
                    ),

                    // Badge: jumlah volume (kalau > 1) atau progress (kalau 1)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color:
                              series.volumeCount > 1
                                  ? Colors.black87
                                  : (series.averageProgress >= 1.0
                                      ? Colors.green
                                      : primaryColor),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          series.volumeCount > 1
                              ? '${series.volumeCount} vol'
                              : (series.averageProgress >= 1.0
                                  ? 'DONE'
                                  : '${(series.averageProgress * 100).toInt()}%'),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),

                    // Tombol delete
                    Positioned(
                      bottom: 12,
                      right: 8,
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: onDelete,
                          borderRadius: BorderRadius.circular(20),
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white10),
                            ),
                            child: const Icon(
                              Icons.delete_outline,
                              size: 18,
                              color: Colors.redAccent,
                            ),
                          ),
                        ),
                      ),
                    ),

                    // Badge format file
                    Positioned(
                      top: 8,
                      left: 8,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Icon(
                          comic.fileType == ComicFileType.pdf
                              ? Icons.picture_as_pdf
                              : Icons.folder_zip,
                          size: 12,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            series.seriesTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: isSmall ? 11 : 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (!isSmall) ...[
            const SizedBox(height: 2),
            Text(
              series.volumeCount > 1
                  ? '${series.volumeCount} volumes'
                  : comic.subtitle,
              style: const TextStyle(fontSize: 12, color: Colors.white38),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCover(Comic comic) {
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
        child: Icon(Icons.book, size: 48, color: Colors.white24),
      ),
    );
  }
}

// ─── Series List Tile (List View) ─────────────────────────────────────────────

class SeriesListTile extends StatelessWidget {
  final ComicSeries series;
  final Color primaryColor;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const SeriesListTile({
    super.key,
    required this.series,
    required this.primaryColor,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final comic = series.representative;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          height: 88,
          decoration: BoxDecoration(
            color: primaryColor.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white10, width: 0.5),
          ),
          child: Row(
            children: [
              // Thumbnail
              ClipRRect(
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(12),
                  bottomLeft: Radius.circular(12),
                ),
                child: SizedBox(
                  width: 60,
                  height: 88,
                  child: _buildCover(comic),
                ),
              ),
              // Info
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        series.seriesTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        series.volumeCount > 1
                            ? '${series.volumeCount} volumes'
                            : comic.subtitle,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white38,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: series.averageProgress.clamp(0.0, 1.0),
                          minHeight: 3,
                          backgroundColor: Colors.white12,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            series.averageProgress >= 1.0
                                ? Colors.green
                                : primaryColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // Badge + delete
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color:
                            series.volumeCount > 1
                                ? Colors.blueGrey
                                : (series.averageProgress >= 1.0
                                    ? Colors.green
                                    : primaryColor),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        series.volumeCount > 1
                            ? '${series.volumeCount}V'
                            : (series.averageProgress >= 1.0
                                ? 'DONE'
                                : '${(series.averageProgress * 100).toInt()}%'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    InkWell(
                      onTap: onDelete,
                      borderRadius: BorderRadius.circular(20),
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Colors.black26,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white10),
                        ),
                        child: const Icon(
                          Icons.delete_outline,
                          size: 16,
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

  Widget _buildCover(Comic comic) {
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
