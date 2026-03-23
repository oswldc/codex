import 'dart:math' as math;
import 'dart:ui';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:pdfx/pdfx.dart';
import '../models/comic.dart';
import '../services/comic_service.dart';
import '../services/reading_history_service.dart';

class ReaderPage extends StatefulWidget {
  final Comic comic;
  final ReadingMode initialReadingMode;

  const ReaderPage({
    super.key,
    required this.comic,
    this.initialReadingMode = ReadingMode.horizontal,
  });

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

enum ReadingMode { horizontal, vertical, manga }

class _ReaderPageState extends State<ReaderPage> {
  bool _showUI = true;
  int _currentPage = 1;
  int _totalPages = -1;

  // For CBZ/CBR: all pages loaded upfront (already fast via ComicService)
  List<Uint8List> _localPages = [];

  // For PDF: lazy per-page cache + shared document
  PdfDocument? _pdfDocument;
  final Map<int, Uint8List> _pdfPageCache = {};
  final Set<int> _pdfPagesRendering = {};

  // PDF cache eviction: keep only ±10 pages around current
  static const int _pdfCacheRadius = 10;

  bool _isLoading = false;
  String _loadingMessage = 'Preparing your comic...';
  late ReadingMode _readingMode;

  late PageController _pageController;

  bool get _isPdf => widget.comic.fileType == ComicFileType.pdf;
  bool get _isManga => _readingMode == ReadingMode.manga;

  @override
  void initState() {
    super.initState();
    _readingMode = widget.initialReadingMode;
    _isLoading = true;
    _pageController = PageController();

    final double initialProgress = widget.comic.progress;
    final int savedPage =
        (widget.comic.currentPage ?? 0) > 0 ? widget.comic.currentPage! : 1;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        if (!mounted) return;

        int total = -1;

        if (_isPdf && widget.comic.localPath != null) {
          setState(() => _loadingMessage = 'Opening PDF...');
          _pdfDocument = await PdfDocument.openFile(widget.comic.localPath!);
          total = _pdfDocument!.pagesCount;
        } else if ((widget.comic.fileType == ComicFileType.cbz ||
                widget.comic.fileType == ComicFileType.cbr) &&
            widget.comic.localPath != null) {
          setState(() => _loadingMessage = 'Extracting pages...');
          _localPages = await ComicService.getPagesFromCBZ(
            widget.comic.localPath!,
          );
          total = _localPages.length;
        } else if (widget.comic.pages.isNotEmpty) {
          total = widget.comic.pages.length;
        }

        if (total > 0) {
          int targetPage = (initialProgress * total).round().clamp(1, total);
          if ((widget.comic.currentPage ?? 0) > 0) {
            targetPage = savedPage.clamp(1, total);
          }

          _pageController.dispose();
          _pageController = PageController(initialPage: targetPage - 1);

          if (mounted) {
            setState(() {
              _totalPages = total;
              _currentPage = targetPage;
              _isLoading = false;
            });
          }

          if (_isPdf) _preRenderAround(targetPage);
        } else {
          if (mounted) {
            setState(() {
              _totalPages = 0;
              _isLoading = false;
            });
          }
        }
      } catch (e) {
        debugPrint('Reader initState error: $e');
        if (mounted) setState(() => _isLoading = false);
      }
    });
  }

  // ── PDF lazy rendering ────────────────────────────────────────────────────

  void _preRenderAround(int page) {
    const int radius = 2;
    final int first = (page - radius).clamp(1, _totalPages);
    final int last = (page + radius).clamp(1, _totalPages);
    for (int p = first; p <= last; p++) {
      _ensurePageRendered(p);
    }
    _evictPdfCache(page);
  }

  /// Evict PDF pages outside the cache window to prevent unbounded memory use.
  void _evictPdfCache(int currentPage) {
    final int keepFrom = (currentPage - _pdfCacheRadius).clamp(1, _totalPages);
    final int keepTo = (currentPage + _pdfCacheRadius).clamp(1, _totalPages);
    _pdfPageCache.removeWhere((page, _) => page < keepFrom || page > keepTo);
  }

  Future<void> _ensurePageRendered(int pageNumber) async {
    if (_pdfDocument == null) return;
    if (_pdfPageCache.containsKey(pageNumber)) return;
    if (_pdfPagesRendering.contains(pageNumber)) return;

    _pdfPagesRendering.add(pageNumber);
    try {
      final PdfPage page = await _pdfDocument!.getPage(pageNumber);
      final PdfPageImage? image = await page.render(
        width: page.width * 2,
        height: page.height * 2,
        format: PdfPageImageFormat.png,
        backgroundColor: '#FFFFFF',
      );
      await page.close();

      if (image != null && mounted) {
        _pdfPageCache[pageNumber] = image.bytes;
        setState(() {});
      }
    } catch (e) {
      debugPrint('PDF render error (page $pageNumber): $e');
    } finally {
      _pdfPagesRendering.remove(pageNumber);
    }
  }

  // ── Navigation ────────────────────────────────────────────────────────────

  void _onPageChanged(int index) {
    // PageView.reverse flips the internal index when in manga mode.
    // The logical page number is always (index + 1) regardless — Flutter
    // handles the visual reversal internally.
    final int page = index + 1;
    setState(() => _currentPage = page);
    if (_isPdf) _preRenderAround(page);

    // Auto-save progress on every page turn
    _saveProgress(page);
  }

  void _jumpToPage(int page) {
    if (_pageController.hasClients) {
      _pageController.jumpToPage(page - 1);
    }
    if (_isPdf) _preRenderAround(page);
  }

  void _saveProgress(int page) {
    final double progress = _totalPages > 0 ? (page / _totalPages) : 0.0;
    ComicService.updateComicProgress(
      widget.comic.id,
      progress,
      currentPage: page,
      totalPages: _totalPages,
    );
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void dispose() {
    // Final save on exit (covers the case where user closes without turning page)
    _saveProgress(_currentPage);

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
    _pdfDocument?.close();
    super.dispose();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

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
          if (!_isLoading && _totalPages > 0) _buildMainContent(primaryColor),
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
    return Container(
      color: Colors.black,
      child: InteractiveViewer(
        minScale: 1.0,
        maxScale: 5.0,
        boundaryMargin: const EdgeInsets.all(20),
        child: PageView.builder(
          scrollDirection:
              _readingMode == ReadingMode.vertical
                  ? Axis.vertical
                  : Axis.horizontal,
          // reverse: true membalik arah scroll PageView untuk mode manga (RTL)
          reverse: _isManga,
          controller: _pageController,
          physics: const BouncingScrollPhysics(),
          onPageChanged: _onPageChanged,
          itemCount: _totalPages,
          itemBuilder: (context, index) {
            final int pageNumber = index + 1;

            // ── PDF ──────────────────────────────────────────────────────────
            if (_isPdf) {
              final Uint8List? cached = _pdfPageCache[pageNumber];
              if (cached != null) {
                return Center(
                  child: Image.memory(
                    cached,
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.medium,
                    gaplessPlayback: true,
                  ),
                );
              }
              _ensurePageRendered(pageNumber);
              return Center(
                child: CircularProgressIndicator(color: primaryColor),
              );
            }

            // ── CBZ / CBR ────────────────────────────────────────────────────
            if (_localPages.isNotEmpty && index < _localPages.length) {
              return Center(
                child: Image.memory(
                  _localPages[index],
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.medium,
                  gaplessPlayback: true,
                  errorBuilder:
                      (context, error, stackTrace) => const Center(
                        child: Icon(Icons.broken_image, color: Colors.white24),
                      ),
                ),
              );
            }

            // ── Network pages ────────────────────────────────────────────────
            if (widget.comic.pages.isNotEmpty &&
                index < widget.comic.pages.length) {
              return CachedNetworkImage(
                imageUrl: widget.comic.pages[index],
                fit: BoxFit.contain,
                placeholder:
                    (context, url) => Center(
                      child: CircularProgressIndicator(color: primaryColor),
                    ),
                errorWidget:
                    (context, url, error) =>
                        const Icon(Icons.error, color: Colors.white24),
              );
            }

            return Center(
              child: CircularProgressIndicator(color: primaryColor),
            );
          },
        ),
      ),
    );
  }

  // ── Bars ──────────────────────────────────────────────────────────────────

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
                  // Badge mode manga
                  if (_isManga) ...[
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.arrow_back,
                            size: 10,
                            color: Colors.white70,
                          ),
                          SizedBox(width: 4),
                          Text(
                            'Manga',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
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
    final bool ready = !_isLoading && _totalPages > 0;
    final int displayTotal = ready ? _totalPages : 1;
    final int displayCurrent = ready ? _currentPage.clamp(1, displayTotal) : 1;

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
          // Label halaman: di manga tampilkan arah balik (kanan → kiri)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white10),
            ),
            child: Text(
              ready ? '$displayCurrent / $displayTotal' : 'Loading...',
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
            child:
                ready
                    ? _isManga
                        // Flip slider secara visual agar konsisten dengan arah baca manga
                        ? Transform(
                          alignment: Alignment.center,
                          transform: Matrix4.rotationY(math.pi),
                          child: _buildSlider(
                            primaryColor,
                            displayCurrent,
                            displayTotal,
                          ),
                        )
                        : _buildSlider(
                          primaryColor,
                          displayCurrent,
                          displayTotal,
                        )
                    : const LinearProgressIndicator(
                      backgroundColor: Colors.white10,
                    ),
          ),
        ],
      ),
    );
  }

  Widget _buildSlider(Color primaryColor, int current, int total) {
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 2,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
        activeTrackColor: primaryColor,
        inactiveTrackColor: Colors.white10,
        thumbColor: Colors.white,
      ),
      child: Slider(
        value: current.toDouble(),
        min: 1,
        max: total.toDouble(),
        onChanged: (value) {
          setState(() => _currentPage = value.toInt());
        },
        onChangeEnd: (value) {
          _jumpToPage(value.toInt());
        },
      ),
    );
  }

  // ── Settings sheet ────────────────────────────────────────────────────────

  void _showSettings(BuildContext context) {
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
                      const SizedBox(width: 8),
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
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildModeButton(
                          Icons.format_textdirection_r_to_l,
                          'Manga',
                          _readingMode == ReadingMode.manga,
                          onTap: () {
                            setState(() => _readingMode = ReadingMode.manga);
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

  // ── Small widgets ─────────────────────────────────────────────────────────

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
