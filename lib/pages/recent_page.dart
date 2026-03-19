import 'dart:io';

import 'package:flutter/material.dart';
import '../models/comic.dart';
import '../services/comic_service.dart';
import 'reader_page.dart';

class RecentPage extends StatefulWidget {
  const RecentPage({super.key});

  @override
  State<RecentPage> createState() => _RecentPageState();
}

class _RecentPageState extends State<RecentPage> {
  List<Comic> _recentComics = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadRecentComics();
  }

  Future<void> _loadRecentComics() async {
    setState(() => _isLoading = true);
    final allComics = await ComicService.loadComics();

    // Filter comics that have been read (lastRead is not null)
    // and sort by lastRead descending (most recent first)
    final recent =
        allComics.where((c) => c.lastRead != null).toList()
          ..sort((a, b) => b.lastRead!.compareTo(a.lastRead!));

    if (mounted) {
      setState(() {
        _recentComics = recent;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final Color primaryColor = Theme.of(context).primaryColor;

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_recentComics.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.history, size: 64, color: Colors.white10),
            const SizedBox(height: 16),
            Text('No recent activity', style: TextStyle(color: Colors.white38)),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _recentComics.length,
      itemBuilder: (context, index) {
        final comic = _recentComics[index];
        return _buildRecentItem(comic, primaryColor);
      },
    );
  }

  Widget _buildRecentItem(Comic comic, Color primaryColor) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: primaryColor.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: InkWell(
        onTap: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => ReaderPage(comic: comic)),
          );
          _loadRecentComics(); // Refresh progress when returning
        },
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              // Comic Cover
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 60,
                  height: 90,
                  child:
                      comic.thumbnailPath != null
                          ? Image.file(
                            File(comic.thumbnailPath!),
                            fit: BoxFit.cover,
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
              const SizedBox(width: 16),
              // Comic Info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      comic.title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      comic.subtitle,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.white38,
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Progress Info
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Page ${comic.currentPage ?? 0} of ${comic.totalPages ?? "0"}',
                          style: TextStyle(
                            fontSize: 12,
                            color: primaryColor.withValues(alpha: 0.8),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          '${(comic.progress * 100).toInt()}%',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.white38,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    // Progress Bar
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: comic.progress,
                        backgroundColor: Colors.white10,
                        valueColor: AlwaysStoppedAnimation<Color>(primaryColor),
                        minHeight: 4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right, color: Colors.white24),
            ],
          ),
        ),
      ),
    );
  }
}
