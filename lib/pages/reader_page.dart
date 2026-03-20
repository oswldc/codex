import 'dart:ui';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:pdfrx/pdfrx.dart';
import '../models/comic.dart';
import '../services/comic_service.dart';
import '../services/reading_history_service.dart';

class ReaderPage extends StatefulWidget {
  final Comic comic;

  const ReaderPage({super.key, required this.comic});

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

enum ReadingMode { horizontal, vertical }

class _ReaderPageState extends State<ReaderPage> {
  bool _showUI = true;
  int _currentPage = 1;
  int _totalPages = -1;
  List<Uint8List> _localPages = [];
  bool _isLoading = false;
  String _loadingMessage = 'Preparing your comic...';
  ReadingMode _readingMode = ReadingMode.horizontal;
  final PdfViewerController _pdfController = PdfViewerController();
  late PageController _pageController;
  bool _isFirstLoad = true;

  @override
  void initState() {
    super.initState();
    _isLoading = true;
    _pageController = PageController();

    double initialProgress = widget.comic.progress;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        if (!mounted) return;

        int total = -1;
        List<Uint8List> localPages = [];

        if ((widget.comic.fileType == ComicFileType.cbz ||
                widget.comic.fileType == ComicFileType.cbr) &&
            widget.comic.localPath != null) {
          setState(() => _loadingMessage = 'Extracting pages...');
          localPages = await ComicService.getPagesFromCBZ(
            widget.comic.localPath!,
          );
          total = localPages.length;
        } else if (widget.comic.pages.isNotEmpty) {
          total = widget.comic.pages.length;
        }

        if (total > 0) {
          int targetPage = (initialProgress * total).round().clamp(1, total);
          _pageController.dispose();
          _pageController = PageController(initialPage: targetPage - 1);

          setState(() {
            _localPages = localPages;
            _totalPages = total;
            _currentPage = targetPage;
            _isLoading = false;
            _isFirstLoad = false;
          });
        } else if (widget.comic.fileType == ComicFileType.pdf) {
          setState(() => _isLoading = false);
        } else {
          setState(() {
            _totalPages = 0;
            _isLoading = false;
            _isFirstLoad = false;
          });
        }
      } catch (e) {
        debugPrint('Reader initState error: $e');
        if (mounted) setState(() => _isLoading = false);
      }
    });

    _pdfController.addListener(() {
      if (!mounted) return;
      final page = _pdfController.pageNumber;
      if (page != null && page != _currentPage) {
        setState(() => _currentPage = page);
      }
      if (_pdfController.pageCount > 0 &&
          (_totalPages == -1 || _totalPages != _pdfController.pageCount)) {
        setState(() => _totalPages = _pdfController.pageCount);

        if (_isFirstLoad && initialProgress > 0) {
          _isFirstLoad = false;
          final total = _pdfController.pageCount;
          final target = (initialProgress * total).round().clamp(1, total);
          _pdfController.goToPage(pageNumber: target);
          setState(() => _currentPage = target);
        } else if (_isFirstLoad) {
          _isFirstLoad = false;
        }
      }
    });
  }

  void _jumpToPage(int page) {
    if (widget.comic.fileType == ComicFileType.pdf) {
      _pdfController.goToPage(pageNumber: page);
    } else {
      if (_pageController.hasClients) {
        _pageController.jumpToPage(page - 1);
      }
    }
  }

  @override
  void dispose() {
    final progress = _totalPages > 0 ? (_currentPage / _totalPages) : 0.0;

    ComicService.updateComicProgress(
      widget.comic.id,
      progress,
      currentPage: _currentPage,
      totalPages: _totalPages,
    );

    ReadingHistoryService.saveEntry(
      ReadingHistoryEntry(
        id: widget.comic.id,
        title: widget.comic.title,
        subtitle: widget.comic.subtitle,
        thumbnailPath: widget.comic.thumbnailPath,
        currentPage: _currentPage,
        totalPages: _totalPages > 0 ? _totalPages : 0,
        lastRead: DateTime.now().millisecondsSinceEpoch,
      ),
    );

    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          GestureDetector(
            onTap: () => setState(() => _showUI = !_showUI),
            child: _buildReaderContent(),
          ),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 300),
            top: _showUI ? 0 : -120,
            left: 0,
            right: 0,
            child: _buildTopBar(context),
          ),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 300),
            bottom: _showUI ? 0 : -180,
            left: 0,
            right: 0,
            child: _buildBottomBar(context),
          ),
        ],
      ),
    );
  }

  Widget _buildReaderContent() {
    final Color primaryColor = Theme.of(context).primaryColor;

    return Container(
      color: Colors.black,
      width: double.infinity,
      height: double.infinity,
      child: Stack(
        children: [
          if (!_isLoading &&
              (_totalPages > 0 || widget.comic.fileType == ComicFileType.pdf))
            _buildMainContent(primaryColor),
          if (!_isLoading && _totalPages == 0)
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.broken_image,
                    color: Colors.white24,
                    size: 64,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'No pages found in this file',
                    style: TextStyle(color: Colors.white38),
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Go Back'),
                  ),
                ],
              ),
            ),
          if (_isLoading)
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(color: primaryColor),
                  const SizedBox(height: 24),
                  Text(
                    _loadingMessage,
                    style: const TextStyle(
                      color: Colors.white60,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMainContent(Color primaryColor) {
    if (widget.comic.fileType == ComicFileType.pdf &&
        widget.comic.localPath != null) {
      return PdfViewer.file(
        widget.comic.localPath!,
        controller: _pdfController,
      );
    }

    return Container(
      color: Colors.black,
      child: InteractiveViewer(
        minScale: 1.0,
        maxScale: 5.0,
        boundaryMargin: const EdgeInsets.all(20),
        child: PageView.builder(
          scrollDirection:
              _readingMode == ReadingMode.horizontal
                  ? Axis.horizontal
                  : Axis.vertical,
          controller: _pageController,
          physics: const BouncingScrollPhysics(),
          onPageChanged: (index) {
            setState(() => _currentPage = index + 1);
          },
          itemCount: _totalPages,
          itemBuilder: (context, index) {
            if (_localPages.isNotEmpty && index < _localPages.length) {
              return Center(
                child: Image.memory(
                  _localPages[index],
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.medium,
                  gaplessPlayback: true,
                  errorBuilder: (context, error, stackTrace) {
                    return const Center(
                      child: Icon(Icons.broken_image, color: Colors.white24),
                    );
                  },
                ),
              );
            }

            if (widget.comic.pages.isNotEmpty &&
                index < widget.comic.pages.length) {
              return CachedNetworkImage(
                imageUrl: widget.comic.pages[index],
                fit: BoxFit.contain,
                placeholder:
                    (context, url) => Center(
                      child: CircularProgressIndicator(color: primaryColor),
                    ),
                errorWidget: (context, url, error) => const Icon(Icons.error),
              );
            }

            return const Center(
              child: CircularProgressIndicator(color: Colors.white24),
            );
          },
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(top: 48, left: 16, right: 16, bottom: 20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black.withValues(alpha: 0.9), Colors.transparent],
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _buildGlassButton(Icons.arrow_back, () => Navigator.pop(context)),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.comic.title,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                  Text(
                    widget.comic.subtitle,
                    style: const TextStyle(color: Colors.white60, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
          _buildGlassButton(Icons.settings, () => _showSettings(context)),
        ],
      ),
    );
  }

  Widget _buildBottomBar(BuildContext context) {
    final Color primaryColor = Theme.of(context).primaryColor;
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black.withValues(alpha: 0.9), Colors.transparent],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white10),
            ),
            child: Text(
              '$_currentPage / $_totalPages',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
            ),
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                activeTrackColor: primaryColor,
                inactiveTrackColor: Colors.white10,
                thumbColor: Colors.white,
              ),
              child: Slider(
                value: _currentPage.toDouble(),
                min: 1,
                max: _totalPages > 0 ? _totalPages.toDouble() : 1,
                onChanged: (value) {
                  setState(() => _currentPage = value.toInt());
                },
                onChangeEnd: (value) {
                  _jumpToPage(value.toInt());
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showSettings(BuildContext context) {
    final Color primaryColor = Theme.of(context).primaryColor;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder:
          (context) => BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
            child: Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).scaffoldBackgroundColor.withValues(alpha: 0.85),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
                border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Reading Settings',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Reading Mode',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _buildModeButton(
                          Icons.swap_horiz,
                          'Page Flip',
                          _readingMode == ReadingMode.horizontal,
                          onTap: () {
                            setState(
                              () => _readingMode = ReadingMode.horizontal,
                            );
                            Navigator.pop(context);
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildModeButton(
                          Icons.view_headline,
                          'Vertical',
                          _readingMode == ReadingMode.vertical,
                          onTap: () {
                            setState(() => _readingMode = ReadingMode.vertical);
                            Navigator.pop(context);
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
    );
  }

  Widget _buildModeButton(
    IconData icon,
    String label,
    bool active, {
    required VoidCallback onTap,
  }) {
    final Color primaryColor = Theme.of(context).primaryColor;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: active ? primaryColor : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: active ? Colors.white10 : Colors.transparent,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: active ? Colors.white : Colors.white38),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: active ? Colors.white : Colors.white38,
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGlassButton(IconData icon, VoidCallback onPressed) {
    return ClipOval(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.1),
            border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
            shape: BoxShape.circle,
          ),
          child: IconButton(
            icon: Icon(icon, color: Colors.white, size: 20),
            onPressed: onPressed,
          ),
        ),
      ),
    );
  }
}
