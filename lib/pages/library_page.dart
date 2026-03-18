import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/comic.dart';
import '../services/comic_service.dart';
import 'comic_detail_page.dart';
import 'recent_page.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  int _selectedIndex = 0;
  final List<Comic> _allComics = [];

  @override
  void initState() {
    super.initState();
    _loadSavedComics();
  }

  Future<void> _loadSavedComics() async {
    // Sync with physical folder first
    final syncedComics = await ComicService.syncWithFolder();
    if (mounted) {
      setState(() {
        _allComics.clear();
        _allComics.addAll(syncedComics);
      });
    }
  }

  Future<void> _deleteComic(Comic comic) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Delete Comic'),
            content: Text(
              'Are you sure you want to delete "${comic.title}"? This will also delete the physical file.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text(
                  'Delete',
                  style: TextStyle(color: Colors.redAccent),
                ),
              ),
            ],
          ),
    );

    if (confirm == true) {
      await ComicService.deleteComic(comic);
      _loadSavedComics();
    }
  }

  Future<void> _addLocalComics() async {
    try {
      debugPrint('LibraryPage: _addLocalComics called');
      final newComics = await ComicService.pickAndParseComics();

      if (newComics.isNotEmpty) {
        await _loadSavedComics(); // Refresh from folder
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Added ${newComics.length} comics to library',
                style: const TextStyle(color: Colors.white),
              ),
              backgroundColor: Theme.of(context).primaryColor,
            ),
          );
        }
      } else {
        debugPrint('LibraryPage: No comics were added (cancelled or empty)');
      }
    } catch (e) {
      debugPrint('LibraryPage Error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Error: $e',
              style: const TextStyle(color: Colors.white),
            ),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  Future<void> _scanLibraryFolder() async {
    try {
      final selectedDir = await ComicService.pickLibraryDirectory();
      if (selectedDir != null) {
        await _loadSavedComics();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Library folder set to $selectedDir',
                style: const TextStyle(color: Colors.white),
              ),
              backgroundColor: Theme.of(context).primaryColor,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('LibraryPage Scan Error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Theme Colors
    final Color primaryColor = Theme.of(context).primaryColor;
    final Color accentColor = Theme.of(context).colorScheme.secondary;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Top Header & Search Bar
            Container(
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
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          _selectedIndex == 0
                              ? 'Codex Library'
                              : _selectedIndex == 1
                              ? 'Recent Reads'
                              : 'Settings',
                          style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                            letterSpacing: -0.5,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            onPressed: _loadSavedComics,
                            icon: const Icon(
                              Icons.refresh,
                              color: Colors.white70,
                            ),
                          ),
                          PopupMenuButton<String>(
                            icon: const Icon(
                              Icons.more_vert,
                              color: Colors.white70,
                            ),
                            onSelected: (value) {
                              if (value == 'scan') {
                                _scanLibraryFolder();
                              }
                            },
                            itemBuilder:
                                (context) => [
                                  const PopupMenuItem(
                                    value: 'scan',
                                    child: Text('Set Library Folder'),
                                  ),
                                ],
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    decoration: InputDecoration(
                      hintText: 'Search your comics...',
                      prefixIcon: const Icon(
                        Icons.search,
                        color: Colors.white38,
                      ),
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
              ),
            ),

            // Content Based on Selected Index
            Expanded(
              child:
                  _selectedIndex == 0
                      ? (_allComics.isEmpty
                          ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.library_books,
                                  size: 64,
                                  color: Colors.white10,
                                ),
                                ElevatedButton(
                                  onPressed: _addLocalComics,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: accentColor,
                                    foregroundColor:
                                        Theme.of(
                                          context,
                                        ).colorScheme.onSecondary,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 24,
                                      vertical: 12,
                                    ),
                                    shape: const StadiumBorder(),
                                  ),
                                  child: const Text('Add Local Comics'),
                                ),
                                const SizedBox(height: 12),
                                OutlinedButton(
                                  onPressed: _scanLibraryFolder,
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.white70,
                                    side: const BorderSide(
                                      color: Colors.white10,
                                    ),
                                    shape: const StadiumBorder(),
                                  ),
                                  child: const Text('Add Library Folder'),
                                ),
                              ],
                            ),
                          )
                          : GridView.builder(
                            padding: const EdgeInsets.all(16),
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 2,
                                  childAspectRatio: 0.6,
                                  crossAxisSpacing: 16,
                                  mainAxisSpacing: 24,
                                ),
                            itemCount: _allComics.length,
                            itemBuilder: (context, index) {
                              final comic = _allComics[index];
                              return ComicCard(
                                comic: comic,
                                onTap: () async {
                                  await Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder:
                                          (context) =>
                                              ComicDetailPage(comic: comic),
                                    ),
                                  );
                                  _loadSavedComics();
                                },
                                onDelete: () => _deleteComic(comic),
                              );
                            },
                          ))
                      : _selectedIndex == 1
                      ? const RecentPage()
                      : const Center(child: Text('Settings Coming Soon')),
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
        child: BottomNavigationBar(
          currentIndex: _selectedIndex,
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          selectedItemColor: accentColor,
          unselectedItemColor: Colors.white38,
          onTap: (index) {
            setState(() {
              _selectedIndex = index;
            });
          },
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.auto_stories),
              label: 'Library',
            ),
            BottomNavigationBarItem(icon: Icon(Icons.history), label: 'Recent'),
            BottomNavigationBarItem(
              icon: Icon(Icons.settings),
              label: 'Settings',
            ),
          ],
        ),
      ),
    );
  }
}

class ComicCard extends StatelessWidget {
  final Comic comic;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const ComicCard({
    super.key,
    required this.comic,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final Color primaryColor = Theme.of(context).primaryColor;

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
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    comic.source == ComicSource.local &&
                            comic.coverBytes != null
                        ? Image.memory(comic.coverBytes!, fit: BoxFit.cover)
                        : comic.imageUrl.isNotEmpty
                        ? CachedNetworkImage(
                          imageUrl: comic.imageUrl,
                          fit: BoxFit.cover,
                          placeholder:
                              (context, url) =>
                                  Container(color: Colors.white10),
                          errorWidget:
                              (context, url, error) => Container(
                                color: Colors.white10,
                                child: Icon(Icons.book, color: Colors.white24),
                              ),
                        )
                        : Container(
                          color: Colors.white10,
                          child: Icon(
                            Icons.book,
                            size: 48,
                            color: Colors.white24,
                          ),
                        ),
                    // Progress Bar
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: Container(
                        height: 4,
                        color: Colors.black45,
                        child: FractionallySizedBox(
                          alignment: Alignment.centerLeft,
                          widthFactor: comic.progress,
                          child: Container(color: primaryColor),
                        ),
                      ),
                    ),
                    // Done Tag
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
                              comic.progress >= 1.0
                                  ? Colors.green
                                  : primaryColor,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          comic.progress >= 1.0
                              ? 'DONE'
                              : '${(comic.progress * 100).toInt()}%',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    // Delete Button
                    Positioned(
                      bottom: 12,
                      right: 8,
                      child: GestureDetector(
                        onTap: () {
                          onDelete();
                        },
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
                    if (comic.source == ComicSource.local)
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
            comic.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(
            '${comic.subtitle}${comic.genre.isNotEmpty ? " • ${comic.genre}" : ""}',
            style: const TextStyle(fontSize: 12, color: Colors.white38),
          ),
        ],
      ),
    );
  }
}
