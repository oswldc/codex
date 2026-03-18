import 'dart:ui';
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
  late Comic _currentComic;

  @override
  void initState() {
    super.initState();
    _currentComic = widget.comic;
    _refreshComic();
  }

  Future<void> _refreshComic() async {
    final comics = await ComicService.loadComics();
    final updated = comics.firstWhere(
      (c) => c.id == _currentComic.id,
      orElse: () => _currentComic,
    );
    if (mounted) {
      setState(() {
        _currentComic = updated;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final Color primaryColor = Theme.of(context).primaryColor;

    return Scaffold(
      body: Stack(
        children: [
          // Cover Image Section
          Container(
            height: MediaQuery.of(context).size.height * 0.5,
            width: double.infinity,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  primaryColor.withValues(alpha: 0.3),
                  Theme.of(context).scaffoldBackgroundColor,
                ],
              ),
            ),
            child: Stack(
              children: [
                // Clear Cover Image
                Center(
                  child: Container(
                    margin: const EdgeInsets.only(top: 60),
                    width: 180,
                    height: 260,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.5),
                          blurRadius: 20,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child:
                          (_currentComic.source == ComicSource.local &&
                                  _currentComic.coverBytes != null)
                              ? Image.memory(
                                _currentComic.coverBytes!,
                                fit: BoxFit.cover,
                              )
                              : _currentComic.imageUrl.isNotEmpty
                              ? CachedNetworkImage(
                                imageUrl: _currentComic.imageUrl,
                                fit: BoxFit.cover,
                                placeholder:
                                    (context, url) => Container(
                                      color: Colors.white10,
                                      child: const Center(
                                        child: CircularProgressIndicator(),
                                      ),
                                    ),
                                errorWidget:
                                    (context, url, error) =>
                                        const Icon(Icons.error),
                              )
                              : Container(
                                color: Colors.white10,
                                child: const Icon(
                                  Icons.book,
                                  size: 48,
                                  color: Colors.white24,
                                ),
                              ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Content
          SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(height: MediaQuery.of(context).size.height * 0.35),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: primaryColor.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: primaryColor.withValues(alpha: 0.3),
                              ),
                            ),
                            child: Text(
                              _currentComic.source == ComicSource.local
                                  ? _currentComic.fileType
                                      .toString()
                                      .split('.')
                                      .last
                                      .toUpperCase()
                                  : 'CBZ',
                              style: TextStyle(
                                color: primaryColor,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              'LOCAL',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _currentComic.title,
                        style: const TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.bold,
                          height: 1.1,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _currentComic.writer ?? 'Various Authors',
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.history,
                                size: 16,
                                color: primaryColor,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                _currentComic.progress > 0
                                    ? '${(_currentComic.progress * 100).toInt()}% Read'
                                    : 'Not read yet',
                                style: const TextStyle(
                                  color: Colors.white38,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                          const Text(
                            'Local Collection',
                            style: TextStyle(
                              color: Colors.white38,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      const Text(
                        'Overview',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _currentComic.description ??
                            'Local file stored at: ${_currentComic.localPath}',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 14,
                          height: 1.6,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          Expanded(
                            child: _buildMetaCard(
                              'Format',
                              _currentComic.fileType
                                  .toString()
                                  .split('.')
                                  .last
                                  .toUpperCase(),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: _buildMetaCard(
                              'Type',
                              _currentComic.source
                                  .toString()
                                  .split('.')
                                  .last
                                  .toUpperCase(),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 120),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Top App Bar Icons
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

          // Bottom CTA
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
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: _currentComic.progress,
                      backgroundColor: Colors.white10,
                      valueColor: AlwaysStoppedAnimation(primaryColor),
                      minHeight: 4,
                    ),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder:
                              (context) => ReaderPage(comic: _currentComic),
                        ),
                      );
                      _refreshComic();
                    },
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
                          _currentComic.progress > 0
                              ? 'Continue Reading'
                              : 'Start Reading',
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

  Widget _buildMetaCard(String label, String value) {
    final Color primaryColor = Theme.of(context).primaryColor;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: primaryColor.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: primaryColor.withValues(alpha: 0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: Colors.white38,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
          ),
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
}
