import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:gal/gal.dart';
import 'package:pdfx/pdfx.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/comic.dart';
import '../services/comic_service.dart';
import '../services/reading_history_service.dart';

// ── Bookmark model ────────────────────────────────────────────────────────────

class Bookmark {
  final int page;
  final String label;
  final int createdAt;

  const Bookmark({
    required this.page,
    required this.label,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
    'page': page,
    'label': label,
    'createdAt': createdAt,
  };

  factory Bookmark.fromJson(Map<String, dynamic> json) => Bookmark(
    page: json['page'] as int,
    label: json['label'] as String,
    createdAt: json['createdAt'] as int,
  );
}

// ─────────────────────────────────────────────────────────────────────────────

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

// Enum untuk melacak sisi tepi gambar yang sedang "mentok" saat pan
enum _EdgeSide { none, left, right, top, bottom }

class _ReaderPageState extends State<ReaderPage>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  bool _showUI = true;
  int _currentPage = 1;
  int _totalPages = -1;

  // For CBZ/CBR: lazy per-page cache
  List<String> _localPagePaths = [];
  final Map<int, Uint8List> _cbzPageCache = {};
  final Set<int> _cbzPagesDecoding = {};
  static const int _cbzCacheRadius = 10;

  // For PDF: lazy per-page cache + shared document
  PdfDocument? _pdfDocument;
  final Map<int, Uint8List> _pdfPageCache = {};
  final Set<int> _pdfPagesRendering = {};
  static const int _pdfCacheRadius = 10;

  bool _isLoading = false;
  String _loadingMessage = 'Preparing your comic...';
  late ReadingMode _readingMode;

  late PageController _pageController;

  // Per-page TransformationController
  final Map<int, TransformationController> _transformControllers = {};
  final Map<int, double> _pageScales = {};

  // Local slider value
  double? _sliderDragValue;

  // Tap zone flash overlay
  bool? _tapFlashRight;

  // AnimationController untuk zoom double-tap
  AnimationController? _zoomAnimController;
  Animation<Matrix4>? _zoomAnimation;
  TransformationController? _activeAnimTarget;

  static const double _doubleTapZoomScale = 1.5;

  // ── ZOOM-AWARE NAVIGATION ─────────────────────────────────────────────────
  // Melacak sisi tepi gambar yang mentok saat pan dalam kondisi zoom.
  // Akumulasi delta overscroll — jika melebihi threshold, pindah halaman.
  _EdgeSide _pannedEdge = _EdgeSide.none;
  double _edgeOverscrollAccum = 0.0;
  static const double _edgeNavThreshold = 60.0; // px sebelum pindah halaman
  Offset? _panStartFocalPoint;

  // Smooth swipe flag
  bool _isSwiping = false;

  // Debounce save
  DateTime? _lastSaved;

  // Bookmark
  List<Bookmark> _bookmarks = [];

  // Mode dual-page
  bool _dualPageMode = false;

  bool get _isPdf => widget.comic.fileType == ComicFileType.pdf;
  bool get _isManga => _readingMode == ReadingMode.manga;
  bool get _isZoomed => (_pageScales[_currentPage] ?? 1.0) > 1.05;

  // ── Controller per halaman ────────────────────────────────────────────────

  TransformationController _controllerForPage(int pageNumber) {
    return _transformControllers.putIfAbsent(
      pageNumber,
      () => TransformationController(),
    );
  }

  void _resetPageZoom(int pageNumber) {
    final ctrl = _transformControllers[pageNumber];
    if (ctrl != null) ctrl.value = Matrix4.identity();
    _pageScales[pageNumber] = 1.0;
  }

  void _evictPageControllers(int currentPage) {
    final keepFrom = (currentPage - _cbzCacheRadius).clamp(1, _totalPages);
    final keepTo = (currentPage + _cbzCacheRadius).clamp(1, _totalPages);
    _transformControllers.removeWhere((page, ctrl) {
      if (page < keepFrom || page > keepTo) {
        ctrl.dispose();
        return true;
      }
      return false;
    });
    _pageScales.removeWhere((page, _) => page < keepFrom || page > keepTo);
  }

  // ── Deteksi tepi: apakah konten sudah mentok di sisi tertentu ────────────
  //
  // Membandingkan translasi saat ini dengan batas minimum yang diizinkan.
  // Hasilnya adalah Set sisi yang sedang menyentuh batas viewport.
  Set<_EdgeSide> _atEdge(TransformationController ctrl) {
    if (!mounted) return {};
    final double scale = ctrl.value.getMaxScaleOnAxis();
    if (scale <= 1.05) return {};

    final Size viewport = MediaQuery.of(context).size;
    final double tx = ctrl.value.getTranslation().x;
    final double ty = ctrl.value.getTranslation().y;
    final double contentW = viewport.width * scale;
    final double contentH = viewport.height * scale;

    // tx = 0 → tepi kiri konten pas di tepi kiri viewport (mentok kiri)
    // tx = viewport.width - contentW → mentok kanan
    final double minTx = viewport.width - contentW;
    final double minTy = viewport.height - contentH;
    const double epsilon = 4.0;

    final result = <_EdgeSide>{};
    if (tx >= -epsilon) result.add(_EdgeSide.left);
    if (tx <= minTx + epsilon) result.add(_EdgeSide.right);
    if (ty >= -epsilon) result.add(_EdgeSide.top);
    if (ty <= minTy + epsilon) result.add(_EdgeSide.bottom);
    return result;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _zoomAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _readingMode = widget.initialReadingMode;
    _isLoading = true;
    _pageController = PageController();
    _loadBookmarks();

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

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
          _localPagePaths = await ComicService.getPagePathsFromCBZ(
            widget.comic.localPath!,
          );
          total = _localPagePaths.length;
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

          if (_isPdf || _localPagePaths.isNotEmpty)
            _preRenderAround(targetPage);
        } else {
          if (mounted)
            setState(() {
              _totalPages = 0;
              _isLoading = false;
            });
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
      if (_isPdf)
        _ensurePdfPageRendered(p);
      else if (_localPagePaths.isNotEmpty)
        _ensureCbzPageDecoded(p);
    }
    if (_isPdf) _evictPdfCache(page);
    if (_localPagePaths.isNotEmpty) _evictCbzCache(page);
    _evictPageControllers(page);
  }

  // ── PDF cache ─────────────────────────────────────────────────────────────

  void _evictPdfCache(int currentPage) {
    final int keepFrom = (currentPage - _pdfCacheRadius).clamp(1, _totalPages);
    final int keepTo = (currentPage + _pdfCacheRadius).clamp(1, _totalPages);
    _pdfPageCache.removeWhere((page, _) => page < keepFrom || page > keepTo);
  }

  Future<void> _ensurePdfPageRendered(int pageNumber) async {
    if (_pdfDocument == null) return;
    if (_pdfPageCache.containsKey(pageNumber)) return;
    if (_pdfPagesRendering.contains(pageNumber)) return;

    _evictPdfCache(pageNumber);
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
        if (!_isSwiping) setState(() {});
      }
    } catch (e) {
      debugPrint('PDF render error (page $pageNumber): $e');
    } finally {
      _pdfPagesRendering.remove(pageNumber);
    }
  }

  // ── CBZ / CBR cache ───────────────────────────────────────────────────────

  void _evictCbzCache(int currentPage) {
    final int keepFrom = (currentPage - _cbzCacheRadius).clamp(1, _totalPages);
    final int keepTo = (currentPage + _cbzCacheRadius).clamp(1, _totalPages);
    _cbzPageCache.removeWhere((page, _) => page < keepFrom || page > keepTo);
  }

  Future<void> _ensureCbzPageDecoded(int pageNumber) async {
    if (_localPagePaths.isEmpty) return;
    if (_cbzPageCache.containsKey(pageNumber)) return;
    if (_cbzPagesDecoding.contains(pageNumber)) return;

    _evictCbzCache(pageNumber);
    _cbzPagesDecoding.add(pageNumber);

    try {
      final Uint8List bytes = await ComicService.getPageBytes(
        widget.comic.localPath!,
        _localPagePaths[pageNumber - 1],
      );
      if (mounted) {
        _cbzPageCache[pageNumber] = bytes;
        if (!_isSwiping) setState(() {});
      }
    } catch (e) {
      debugPrint('CBZ decode error (page $pageNumber): $e');
    } finally {
      _cbzPagesDecoding.remove(pageNumber);
    }
  }

  // ── Navigation ────────────────────────────────────────────────────────────

  void _onPageChanged(int index) {
    final bool useDual = _dualPageMode && _readingMode != ReadingMode.vertical;
    final int page =
        useDual ? (index * 2 + 1).clamp(1, _totalPages) : index + 1;

    setState(() {
      _currentPage = page;
      _sliderDragValue = null;
      _isSwiping = false;
      _pannedEdge = _EdgeSide.none;
      _edgeOverscrollAccum = 0.0;
    });

    _resetPageZoom(page);
    _preRenderAround(page);
    _saveProgress(page);
  }

  void _jumpToPage(int page) {
    if (_pageController.hasClients) {
      final bool useDual =
          _dualPageMode && _readingMode != ReadingMode.vertical;
      final int targetIndex = useDual ? ((page - 1) ~/ 2) : page - 1;
      _pageController.jumpToPage(targetIndex);
    }
    _preRenderAround(page);
  }

  void _navigateNext() {
    _resetPageZoom(_currentPage);
    _pageController.nextPage(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  void _navigatePrev() {
    _resetPageZoom(_currentPage);
    _pageController.previousPage(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  // ── Tap navigation ────────────────────────────────────────────────────────

  void _handleTapNavigation(Offset localPosition) {
    if (_isZoomed) {
      // Saat zoom aktif, tap hanya untuk toggle UI di zona tengah.
      // Navigasi antar halaman dilakukan lewat edge-pan.
      final double screenWidth = MediaQuery.of(context).size.width;
      final double zoneWidth = screenWidth * 0.25;
      final bool tapCenter =
          localPosition.dx >= zoneWidth &&
          localPosition.dx <= screenWidth - zoneWidth;
      if (tapCenter) setState(() => _showUI = !_showUI);
      return;
    }

    final double screenWidth = MediaQuery.of(context).size.width;
    final double zoneWidth = screenWidth * 0.25;
    final bool tapLeft = localPosition.dx < zoneWidth;
    final bool tapRight = localPosition.dx > screenWidth - zoneWidth;

    if (!tapLeft && !tapRight) {
      setState(() => _showUI = !_showUI);
      return;
    }

    final bool goNext = _isManga ? tapLeft : tapRight;
    final bool goPrev = _isManga ? tapRight : tapLeft;

    if (goNext) {
      if (_currentPage < _totalPages) {
        _showTapFlash(isRight: true);
        _navigateNext();
      } else {
        HapticFeedback.lightImpact();
      }
    } else if (goPrev) {
      if (_currentPage > 1) {
        _showTapFlash(isRight: false);
        _navigatePrev();
      } else {
        HapticFeedback.lightImpact();
      }
    }
  }

  // ── ZOOM-AWARE NAVIGATION: edge-pan handlers ──────────────────────────────

  void _onInteractionStart(
    ScaleStartDetails details,
    TransformationController ctrl,
  ) {
    _panStartFocalPoint = details.focalPoint;
    _pannedEdge = _EdgeSide.none;
    _edgeOverscrollAccum = 0.0;
  }

  void _onInteractionUpdate(
    ScaleUpdateDetails details,
    TransformationController ctrl,
    int pageNumber,
  ) {
    // Update skala untuk throttle setState
    final scale = ctrl.value.getMaxScaleOnAxis();
    final prev = _pageScales[pageNumber] ?? 1.0;
    if ((prev - scale).abs() > 0.02) {
      setState(() => _pageScales[pageNumber] = scale);
    }

    // Edge-pan hanya berlaku saat zoom aktif dan gesture satu jari
    if (!_isZoomed || details.pointerCount != 1) {
      if (details.pointerCount > 1) {
        // Pinch gesture — reset akumulasi
        _pannedEdge = _EdgeSide.none;
        _edgeOverscrollAccum = 0.0;
      }
      return;
    }

    final Set<_EdgeSide> edges = _atEdge(ctrl);
    final Offset delta = details.focalPointDelta;
    final bool isHorizontal = _readingMode != ReadingMode.vertical;

    if (isHorizontal) {
      // Delta negatif (geser kiri) + konten mentok di kanan → ingin next
      // Delta positif (geser kanan) + konten mentok di kiri → ingin prev
      if (delta.dx < 0 && edges.contains(_EdgeSide.right)) {
        if (_pannedEdge != _EdgeSide.right) {
          _pannedEdge = _EdgeSide.right;
          _edgeOverscrollAccum = 0.0;
        }
        _edgeOverscrollAccum += delta.dx.abs();
      } else if (delta.dx > 0 && edges.contains(_EdgeSide.left)) {
        if (_pannedEdge != _EdgeSide.left) {
          _pannedEdge = _EdgeSide.left;
          _edgeOverscrollAccum = 0.0;
        }
        _edgeOverscrollAccum += delta.dx.abs();
      } else {
        _pannedEdge = _EdgeSide.none;
        _edgeOverscrollAccum = 0.0;
      }
    } else {
      if (delta.dy < 0 && edges.contains(_EdgeSide.bottom)) {
        if (_pannedEdge != _EdgeSide.bottom) {
          _pannedEdge = _EdgeSide.bottom;
          _edgeOverscrollAccum = 0.0;
        }
        _edgeOverscrollAccum += delta.dy.abs();
      } else if (delta.dy > 0 && edges.contains(_EdgeSide.top)) {
        if (_pannedEdge != _EdgeSide.top) {
          _pannedEdge = _EdgeSide.top;
          _edgeOverscrollAccum = 0.0;
        }
        _edgeOverscrollAccum += delta.dy.abs();
      } else {
        _pannedEdge = _EdgeSide.none;
        _edgeOverscrollAccum = 0.0;
      }
    }
  }

  void _onInteractionEnd(ScaleEndDetails details, int pageNumber) {
    final scale =
        _transformControllers[pageNumber]?.value.getMaxScaleOnAxis() ?? 1.0;
    if (scale <= 1.05) setState(() => _pageScales[pageNumber] = 1.0);

    // Eksekusi navigasi jika akumulasi overscroll cukup
    if (_isZoomed && _edgeOverscrollAccum >= _edgeNavThreshold) {
      final bool isHorizontal = _readingMode != ReadingMode.vertical;

      if (isHorizontal) {
        // Tepi kanan mentok + dorong kiri = maju (kecuali manga: mundur)
        final bool wantsNext = _pannedEdge == _EdgeSide.right;
        final bool wantsPrev = _pannedEdge == _EdgeSide.left;
        final bool goNext = _isManga ? wantsPrev : wantsNext;
        final bool goPrev = _isManga ? wantsNext : wantsPrev;

        if (goNext && _currentPage < _totalPages) {
          HapticFeedback.lightImpact();
          _navigateNext();
        } else if (goPrev && _currentPage > 1) {
          HapticFeedback.lightImpact();
          _navigatePrev();
        } else {
          // Boundary — beri feedback tanpa pindah
          HapticFeedback.lightImpact();
        }
      } else {
        if (_pannedEdge == _EdgeSide.bottom && _currentPage < _totalPages) {
          HapticFeedback.lightImpact();
          _navigateNext();
        } else if (_pannedEdge == _EdgeSide.top && _currentPage > 1) {
          HapticFeedback.lightImpact();
          _navigatePrev();
        } else {
          HapticFeedback.lightImpact();
        }
      }
    }

    _pannedEdge = _EdgeSide.none;
    _edgeOverscrollAccum = 0.0;
    _panStartFocalPoint = null;
  }

  void _showTapFlash({required bool isRight}) {
    setState(() => _tapFlashRight = isRight);
    Future.delayed(const Duration(milliseconds: 120), () {
      if (mounted) setState(() => _tapFlashRight = null);
    });
  }

  // ── Bookmark ──────────────────────────────────────────────────────────────

  Future<void> _loadBookmarks() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('bookmarks_${widget.comic.id}');
    if (raw != null && mounted) {
      final List decoded = jsonDecode(raw);
      setState(() {
        _bookmarks = decoded.map((e) => Bookmark.fromJson(e)).toList();
      });
    }
  }

  Future<void> _saveBookmarks() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'bookmarks_${widget.comic.id}',
      jsonEncode(_bookmarks.map((b) => b.toJson()).toList()),
    );
  }

  // ── Save to gallery ───────────────────────────────────────────────────────

  Future<void> _saveCurrentPageToGallery() async {
    final bool useDual = _dualPageMode && _readingMode != ReadingMode.vertical;

    try {
      final hasAccess = await Gal.hasAccess();
      if (!hasAccess) await Gal.requestAccess();

      if (useDual) {
        final int leftPage = _isManga ? _currentPage + 1 : _currentPage;
        final int rightPage = _isManga ? _currentPage : _currentPage + 1;

        final Uint8List? leftBytes = _getPageBytes(leftPage);
        final Uint8List? rightBytes = _getPageBytes(rightPage);

        if (leftBytes == null && rightBytes == null) {
          _showSnackBar('Halaman belum selesai dimuat', isError: true);
          return;
        }

        final Uint8List merged = await _mergePages(leftBytes, rightBytes);
        final fileName =
            '${widget.comic.title}_hal${leftPage}-${rightPage}_'
            '${DateTime.now().millisecondsSinceEpoch}.jpg';
        await Gal.putImageBytes(merged, name: fileName);
        _showSnackBar('Halaman $leftPage–$rightPage disimpan ke galeri');
      } else {
        final Uint8List? bytes = _getPageBytes(_currentPage);
        if (bytes == null) {
          _showSnackBar('Halaman belum selesai dimuat', isError: true);
          return;
        }
        final fileName =
            '${widget.comic.title}_hal${_currentPage}_'
            '${DateTime.now().millisecondsSinceEpoch}.jpg';
        await Gal.putImageBytes(bytes, name: fileName);
        _showSnackBar('Halaman $_currentPage disimpan ke galeri');
      }
    } catch (e) {
      debugPrint('Save to gallery error: $e');
      _showSnackBar('Gagal menyimpan gambar', isError: true);
    }
  }

  Uint8List? _getPageBytes(int pageNumber) {
    if (_isPdf) return _pdfPageCache[pageNumber];
    if (_localPagePaths.isNotEmpty) return _cbzPageCache[pageNumber];
    return null;
  }

  Future<Uint8List> _mergePages(
    Uint8List? leftBytes,
    Uint8List? rightBytes,
  ) async {
    final ui.Image? leftImg = await _decodeImage(leftBytes);
    final ui.Image? rightImg = await _decodeImage(rightBytes);

    final int w = (leftImg?.width ?? rightImg?.width ?? 800);
    final int h = (leftImg?.height ?? rightImg?.height ?? 1200);

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);

    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, (w * 2).toDouble(), h.toDouble()),
      ui.Paint()..color = const Color(0xFF000000),
    );

    if (leftImg != null) canvas.drawImage(leftImg, ui.Offset.zero, ui.Paint());
    if (rightImg != null)
      canvas.drawImage(rightImg, ui.Offset(w.toDouble(), 0), ui.Paint());

    final picture = recorder.endRecording();
    final img = await picture.toImage(w * 2, h);
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }

  Future<ui.Image?> _decodeImage(Uint8List? bytes) async {
    if (bytes == null) return null;
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  void _showSnackBar(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red.shade700 : Colors.green.shade700,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 80),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // ── Jump-to-page dialog ───────────────────────────────────────────────────

  void _showJumpToPageDialog() {
    final controller = TextEditingController(text: '$_currentPage');
    final primaryColor = Theme.of(context).primaryColor;

    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
            ),
            title: const Text(
              'Jump to Page',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: controller,
                    keyboardType: TextInputType.number,
                    autofocus: true,
                    style: const TextStyle(fontSize: 16),
                    decoration: InputDecoration(
                      hintText: '1 – $_totalPages',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: primaryColor),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                    ),
                    onSubmitted: (value) {
                      final page = int.tryParse(value);
                      if (page != null && page >= 1 && page <= _totalPages) {
                        _jumpToPage(page);
                        Navigator.pop(context);
                      }
                    },
                  ),
                  if (_bookmarks.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    const Text(
                      'Bookmarks',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.white54,
                      ),
                    ),
                    const SizedBox(height: 6),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 220),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: _bookmarks.length,
                        itemBuilder: (context, i) {
                          final b = _bookmarks[i];
                          return ListTile(
                            dense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 4,
                            ),
                            leading: Icon(
                              Icons.bookmark,
                              size: 16,
                              color: primaryColor,
                            ),
                            title: Text(
                              b.label,
                              style: const TextStyle(fontSize: 14),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'Hal. ${b.page}',
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: 12,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                GestureDetector(
                                  onTap: () async {
                                    setState(() => _bookmarks.removeAt(i));
                                    await _saveBookmarks();
                                    if (context.mounted) {
                                      Navigator.pop(context);
                                      _showJumpToPageDialog();
                                    }
                                  },
                                  child: const Icon(
                                    Icons.close,
                                    size: 14,
                                    color: Colors.white38,
                                  ),
                                ),
                              ],
                            ),
                            onTap: () {
                              _jumpToPage(b.page);
                              Navigator.pop(context);
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Batal'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: primaryColor),
                onPressed: () {
                  final page = int.tryParse(controller.text);
                  if (page != null && page >= 1 && page <= _totalPages) {
                    _jumpToPage(page);
                    Navigator.pop(context);
                  }
                },
                child: const Text('Go'),
              ),
            ],
          ),
    );
  }

  void _saveProgress(int page, {bool force = false}) {
    final now = DateTime.now();
    if (!force &&
        _lastSaved != null &&
        now.difference(_lastSaved!).inSeconds < 2)
      return;

    _lastSaved = now;
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
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _saveProgress(_currentPage, force: true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _saveProgress(_currentPage, force: true);

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    if (widget.comic.localPath != null) {
      ComicService.closeArchive(widget.comic.localPath!);
    }

    for (final ctrl in _transformControllers.values) ctrl.dispose();
    _transformControllers.clear();

    _zoomAnimController?.dispose();

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
          _buildReaderContent(),
          if (_tapFlashRight != null) _buildTapZoneFlash(_tapFlashRight!),
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

  Widget _buildTapZoneFlash(bool isRight) {
    final screenWidth = MediaQuery.of(context).size.width;
    final zoneWidth = screenWidth * 0.25;
    return Positioned(
      top: 0,
      bottom: 0,
      left: isRight ? screenWidth - zoneWidth : 0,
      width: zoneWidth,
      child: IgnorePointer(
        child: AnimatedOpacity(
          opacity: _tapFlashRight != null ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 80),
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: isRight ? Alignment.centerRight : Alignment.centerLeft,
                end: isRight ? Alignment.centerLeft : Alignment.centerRight,
                colors: [
                  Colors.white.withValues(alpha: 0.12),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
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
    final bool useDual = _dualPageMode && _readingMode != ReadingMode.vertical;
    final int itemCount = useDual ? ((_totalPages + 1) ~/ 2) : _totalPages;

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollStartNotification) {
          _isSwiping = true;
        } else if (notification is ScrollEndNotification) {
          if (_isSwiping) _isSwiping = false;
        }
        return false;
      },
      child: PageView.builder(
        scrollDirection:
            _readingMode == ReadingMode.vertical
                ? Axis.vertical
                : Axis.horizontal,
        reverse: _isManga,
        controller: _pageController,
        // PageView tetap diblokir saat zoom — navigasi via edge-pan
        physics:
            _isZoomed
                ? const NeverScrollableScrollPhysics()
                : const ClampingScrollPhysics(),
        onPageChanged: _onPageChanged,
        itemCount: itemCount,
        itemBuilder: (context, slotIndex) {
          if (!useDual) return _buildZoomablePage(slotIndex + 1, primaryColor);

          final int leftPage = _isManga ? slotIndex * 2 + 2 : slotIndex * 2 + 1;
          final int rightPage =
              _isManga ? slotIndex * 2 + 1 : slotIndex * 2 + 2;
          final int primaryPage = slotIndex * 2 + 1;
          final ctrl = _controllerForPage(primaryPage);

          return GestureDetector(
            onTapUp: (details) => _handleTapNavigation(details.localPosition),
            onDoubleTapDown:
                (details) => _handleDoubleTap(details, primaryPage),
            onDoubleTap: () {},
            child: InteractiveViewer(
              transformationController: ctrl,
              minScale: 1.0,
              maxScale: 5.0,
              boundaryMargin: const EdgeInsets.all(20),
              onInteractionStart:
                  (details) => _onInteractionStart(details, ctrl),
              onInteractionUpdate:
                  (details) => _onInteractionUpdate(details, ctrl, primaryPage),
              onInteractionEnd:
                  (details) => _onInteractionEnd(details, primaryPage),
              child: Row(
                children: [
                  Expanded(
                    child:
                        leftPage <= _totalPages
                            ? _buildPageContent(leftPage - 1, primaryColor)
                            : const SizedBox.shrink(),
                  ),
                  Expanded(
                    child:
                        rightPage <= _totalPages
                            ? _buildPageContent(rightPage - 1, primaryColor)
                            : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ── Double-tap zoom ───────────────────────────────────────────────────────

  void _handleDoubleTap(TapDownDetails details, int pageNumber) {
    final ctrl = _controllerForPage(pageNumber);
    final double currentScale = _pageScales[pageNumber] ?? 1.0;
    final bool isZoomedIn = currentScale > 1.05;

    if (isZoomedIn) {
      _animateZoom(Matrix4.identity(), ctrl, pageNumber, targetScale: 1.0);
      return;
    }

    final Offset tap = details.localPosition;
    final double x = -tap.dx * (_doubleTapZoomScale - 1);
    final double y = -tap.dy * (_doubleTapZoomScale - 1);
    final Matrix4 zoomed =
        Matrix4.identity()
          ..translate(x, y)
          ..scale(_doubleTapZoomScale);

    _animateZoom(zoomed, ctrl, pageNumber, targetScale: _doubleTapZoomScale);
  }

  void _animateZoom(
    Matrix4 target,
    TransformationController ctrl,
    int pageNumber, {
    required double targetScale,
  }) {
    _zoomAnimController!.stop();
    _activeAnimTarget = ctrl;
    _zoomAnimation = Matrix4Tween(begin: ctrl.value, end: target).animate(
      CurvedAnimation(parent: _zoomAnimController!, curve: Curves.easeInOut),
    )..addListener(() {
      if (_activeAnimTarget == ctrl) {
        ctrl.value = _zoomAnimation!.value;
        final scale = ctrl.value.getMaxScaleOnAxis();
        if ((_pageScales[pageNumber] ?? 1.0 - scale).abs() > 0.01) {
          setState(() => _pageScales[pageNumber] = scale);
        }
      }
    });
    _zoomAnimController!
      ..reset()
      ..forward().then((_) {
        if (mounted) setState(() => _pageScales[pageNumber] = targetScale);
      });
  }

  // ── Zoomable page (single-page mode) ─────────────────────────────────────

  Widget _buildZoomablePage(int pageNumber, Color primaryColor) {
    final ctrl = _controllerForPage(pageNumber);

    return GestureDetector(
      onTapUp: (details) => _handleTapNavigation(details.localPosition),
      onDoubleTapDown: (details) => _handleDoubleTap(details, pageNumber),
      onDoubleTap: () {},
      child: InteractiveViewer(
        transformationController: ctrl,
        minScale: 1.0,
        maxScale: 5.0,
        boundaryMargin: const EdgeInsets.all(20),
        onInteractionStart: (details) => _onInteractionStart(details, ctrl),
        onInteractionUpdate:
            (details) => _onInteractionUpdate(details, ctrl, pageNumber),
        onInteractionEnd: (details) => _onInteractionEnd(details, pageNumber),
        child: _buildPageContent(pageNumber - 1, primaryColor),
      ),
    );
  }

  Widget _buildPageContent(int index, Color primaryColor) {
    final int pageNumber = index + 1;

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
      _ensurePdfPageRendered(pageNumber);
      return Center(child: CircularProgressIndicator(color: primaryColor));
    }

    if (_localPagePaths.isNotEmpty) {
      final Uint8List? cached = _cbzPageCache[pageNumber];
      if (cached != null) {
        return Center(
          child: Image.memory(
            cached,
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
      _ensureCbzPageDecoded(pageNumber);
      return Center(child: CircularProgressIndicator(color: primaryColor));
    }

    if (widget.comic.pages.isNotEmpty && index < widget.comic.pages.length) {
      return CachedNetworkImage(
        imageUrl: widget.comic.pages[index],
        fit: BoxFit.contain,
        placeholder:
            (context, url) =>
                Center(child: CircularProgressIndicator(color: primaryColor)),
        errorWidget:
            (context, url, error) =>
                const Icon(Icons.error, color: Colors.white24),
      );
    }

    return Center(child: CircularProgressIndicator(color: primaryColor));
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
          GestureDetector(
            onTap: ready ? _showJumpToPageDialog : null,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    ready ? '$displayCurrent / $displayTotal' : 'Loading...',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  if (ready) ...[
                    const SizedBox(width: 6),
                    const Icon(
                      Icons.unfold_more,
                      size: 14,
                      color: Colors.white38,
                    ),
                  ],
                ],
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
    final double sliderValue = (_sliderDragValue ?? current.toDouble()).clamp(
      1.0,
      total.toDouble(),
    );

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
        value: sliderValue,
        min: 1,
        max: total.toDouble(),
        onChanged: (value) => setState(() => _sliderDragValue = value),
        onChangeEnd: (value) {
          setState(() => _sliderDragValue = null);
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
            filter: ui.ImageFilter.blur(sigmaX: 15, sigmaY: 15),
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
                  const Text(
                    'Opsi',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 12),
                  StatefulBuilder(
                    builder:
                        (context, setSheetState) => Column(
                          children: [
                            _buildSettingsRow(
                              icon: Icons.auto_stories,
                              label: '2 Halaman',
                              subtitle: 'Tampilkan dua halaman berdampingan',
                              trailing: Switch(
                                value: _dualPageMode,
                                onChanged: (_) {
                                  setState(() {
                                    _dualPageMode = !_dualPageMode;
                                    final bool useDual =
                                        _dualPageMode &&
                                        _readingMode != ReadingMode.vertical;
                                    _pageController.jumpToPage(
                                      useDual
                                          ? ((_currentPage - 1) ~/ 2)
                                          : _currentPage - 1,
                                    );
                                  });
                                  setSheetState(() {});
                                },
                              ),
                            ),
                            const SizedBox(height: 8),
                            _buildSettingsRow(
                              icon: Icons.save_alt,
                              label: 'Simpan ke Galeri',
                              subtitle: 'Simpan halaman ini sebagai gambar',
                              trailing: IconButton(
                                icon: const Icon(
                                  Icons.chevron_right,
                                  color: Colors.white38,
                                ),
                                onPressed: () {
                                  Navigator.pop(context);
                                  _saveCurrentPageToGallery();
                                },
                              ),
                              onTap: () {
                                Navigator.pop(context);
                                _saveCurrentPageToGallery();
                              },
                            ),
                          ],
                        ),
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
        filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
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

  Widget _buildSettingsRow({
    required IconData icon,
    required String label,
    required String subtitle,
    required Widget trailing,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: Colors.white60),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: const TextStyle(fontSize: 12, color: Colors.white38),
                  ),
                ],
              ),
            ),
            trailing,
          ],
        ),
      ),
    );
  }
}
