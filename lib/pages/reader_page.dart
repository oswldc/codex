import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:gal/gal.dart';
import 'package:pdfx/pdfx.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/comic.dart';
import '../services/comic_service.dart';
import '../services/reading_history_service.dart';
import 'package:flutter/scheduler.dart';

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

// ── AllowMultipleScaleRecognizer ──────────────────────────────────────────────

class _AllowMultipleScaleRecognizer extends ScaleGestureRecognizer {
  _AllowMultipleScaleRecognizer({super.debugOwner});

  int _pointerCount = 0;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    _pointerCount++;
    if (_pointerCount >= 2) {
      acceptGesture(event.pointer);
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _pointerCount = 0;
    super.didStopTrackingLastPointer(pointer);
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class ReaderPage extends StatefulWidget {
  final Comic comic;
  final ReadingMode initialReadingMode;

  /// Jika tidak null, dialog "Volume Selesai" akan menawarkan
  /// untuk lanjut ke volume ini.
  final Comic? nextVolume;

  const ReaderPage({
    super.key,
    required this.comic,
    this.initialReadingMode = ReadingMode.horizontal,
    this.nextVolume,
  });

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

enum ReadingMode { horizontal, vertical, manga }

class _ReaderPageState extends State<ReaderPage>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  bool _showUI = true;
  int _currentPage = 1;
  int _totalPages = -1;

  // For CBZ/CBR: lazy per-page cache via ValueNotifier
  List<String> _localPagePaths = [];
  final Map<int, ValueNotifier<Uint8List?>> _cbzNotifiers = {};
  final Set<int> _cbzPagesDecoding = {};
  static const int _cbzCacheRadius = 10;

  // For PDF: lazy per-page cache via ValueNotifier + shared document
  PdfDocument? _pdfDocument;
  final Map<int, ValueNotifier<Uint8List?>> _pdfNotifiers = {};
  final Set<int> _pdfPagesRendering = {};

  bool _isLoading = false;
  String _loadingMessage = 'Preparing your comic...';
  late ReadingMode _readingMode;

  late PageController _pageController;

  // Per-page zoom state (Matrix4 via ValueNotifier)
  final Map<int, ValueNotifier<Matrix4>> _zoomNotifiers = {};

  final ValueNotifier<bool> _pageScrollLocked = ValueNotifier<bool>(false);

  // Local slider value
  double? _sliderDragValue;

  // Tap zone flash overlay
  bool? _tapFlashRight;

  // Debounce save
  DateTime? _lastSaved;

  // Bookmark
  List<Bookmark> _bookmarks = [];

  // Mode dual-page
  bool _dualPageMode = false;

  // ── Swipe-down-to-dismiss ─────────────────────────────────────────────────
  // Offset vertikal saat user drag ke bawah
  final ValueNotifier<double> _dismissDragOffset = ValueNotifier<double>(0.0);
  // Animasi snap-back saat drag dibatalkan
  late AnimationController _dismissSnapController;
  Animation<double>? _dismissSnapAnim;
  static const double _dismissThreshold = 150.0;
  static const double _dismissMaxDrag = 300.0;
  // Guard agar dialog volume selesai tidak muncul dua kali
  bool _volumeCompleteShown = false;

  bool get _isPdf => widget.comic.fileType == ComicFileType.pdf;
  bool get _isManga => _readingMode == ReadingMode.manga;

  bool _isPageZoomed(int pageNumber) {
    final m = _zoomNotifiers[pageNumber]?.value;
    if (m == null) return false;
    return m.getMaxScaleOnAxis() > 1.05;
  }

  // ── ValueNotifier helpers ─────────────────────────────────────────────────

  ValueNotifier<Uint8List?> _cbzNotifierFor(int pageNumber) {
    return _cbzNotifiers.putIfAbsent(
      pageNumber,
      () => ValueNotifier<Uint8List?>(null),
    );
  }

  ValueNotifier<Uint8List?> _pdfNotifierFor(int pageNumber) {
    return _pdfNotifiers.putIfAbsent(
      pageNumber,
      () => ValueNotifier<Uint8List?>(null),
    );
  }

  ValueNotifier<Matrix4> _zoomNotifierFor(int pageNumber) {
    return _zoomNotifiers.putIfAbsent(
      pageNumber,
      () => ValueNotifier<Matrix4>(Matrix4.identity()),
    );
  }

  void _evictCaches(int currentPage) {
    final keepFrom = (currentPage - _cbzCacheRadius).clamp(1, _totalPages);
    final keepTo = (currentPage + _cbzCacheRadius).clamp(1, _totalPages);

    _cbzNotifiers.removeWhere((page, notifier) {
      if (page < keepFrom || page > keepTo) {
        notifier.dispose();
        return true;
      }
      return false;
    });
    _pdfNotifiers.removeWhere((page, notifier) {
      if (page < keepFrom || page > keepTo) {
        notifier.dispose();
        return true;
      }
      return false;
    });

    final zoomKeepFrom = (currentPage - 3).clamp(1, _totalPages);
    final zoomKeepTo = (currentPage + 3).clamp(1, _totalPages);
    _zoomNotifiers.removeWhere((page, notifier) {
      if (page < zoomKeepFrom || page > zoomKeepTo) {
        notifier.dispose();
        return true;
      }
      return false;
    });
  }

  void _resetPageZoom(int pageNumber) {
    _zoomNotifiers[pageNumber]?.value = Matrix4.identity();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _readingMode = widget.initialReadingMode;
    _isLoading = true;
    _pageController = PageController();
    _loadBookmarks();

    // Animasi snap-back dismiss
    _dismissSnapController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );

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

  // ── Prefetch ──────────────────────────────────────────────────────────────

  void _preRenderAround(int page) {
    final int first = (page - 1).clamp(1, _totalPages);
    final int last = (page + 3).clamp(1, _totalPages);
    for (int p = first; p <= last; p++) {
      if (_isPdf)
        _ensurePdfPageRendered(p);
      else if (_localPagePaths.isNotEmpty)
        _ensureCbzPageDecoded(p);
    }
    _evictCaches(page);
  }

  // ── PDF rendering ─────────────────────────────────────────────────────────

  Future<void> _ensurePdfPageRendered(int pageNumber) async {
    if (_pdfDocument == null) return;
    final notifier = _pdfNotifierFor(pageNumber);
    if (notifier.value != null) return;
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
      if (image != null && mounted) notifier.value = image.bytes;
    } catch (e) {
      debugPrint('PDF render error (page $pageNumber): $e');
    } finally {
      _pdfPagesRendering.remove(pageNumber);
    }
  }

  // ── CBZ / CBR decoding ────────────────────────────────────────────────────

  Future<void> _ensureCbzPageDecoded(int pageNumber) async {
    if (_localPagePaths.isEmpty) return;
    final notifier = _cbzNotifierFor(pageNumber);
    if (notifier.value != null) return;
    if (_cbzPagesDecoding.contains(pageNumber)) return;

    _cbzPagesDecoding.add(pageNumber);
    try {
      final Uint8List bytes = await ComicService.getPageBytes(
        widget.comic.localPath!,
        _localPagePaths[pageNumber - 1],
      );
      if (mounted) notifier.value = bytes;
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
    });

    _resetPageZoom(page);
    _pageScrollLocked.value = false;
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
    // Jika sudah di halaman terakhir → tampilkan dialog volume selesai
    if (_currentPage >= _totalPages) {
      _showVolumeCompleteDialog();
      return;
    }
    _pageController.nextPage(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
    );
  }

  void _navigatePrev() {
    _resetPageZoom(_currentPage);
    _pageController.previousPage(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
    );
  }

  // ── Volume complete dialog ────────────────────────────────────────────────

  void _showVolumeCompleteDialog() {
    if (_volumeCompleteShown) return;
    _volumeCompleteShown = true;

    HapticFeedback.mediumImpact();

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Tutup',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 350),
      pageBuilder: (_, __, ___) => const SizedBox.shrink(),
      transitionBuilder: (context, anim, _, __) {
        final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutBack);
        return ScaleTransition(
          scale: Tween<double>(begin: 0.85, end: 1.0).animate(curved),
          child: FadeTransition(
            opacity: anim,
            child: _VolumeCompleteDialog(
              comic: widget.comic,
              nextVolume: widget.nextVolume,
              onStay: () {
                Navigator.pop(context);
                // Tetap di halaman terakhir, reset guard agar bisa dibuka lagi
                // jika user swipe balik lalu maju lagi
                Future.delayed(
                  const Duration(milliseconds: 400),
                  () => _volumeCompleteShown = false,
                );
              },
              onNextVolume:
                  widget.nextVolume == null
                      ? null
                      : () {
                        Navigator.pop(context); // tutup dialog
                        // Ganti reader dengan volume berikutnya
                        Navigator.pushReplacement(
                          context,
                          _FadeSlideRoute(
                            page: ReaderPage(
                              comic: widget.nextVolume!,
                              initialReadingMode: _readingMode,
                              // nextVolume berikutnya bisa di-pass dari parent
                            ),
                          ),
                        );
                      },
            ),
          ),
        );
      },
    );
  }

  // ── Swipe-down-to-dismiss ─────────────────────────────────────────────────

  /// Dipanggil dari _ZoomPage saat user drag ke bawah (tidak zoom).
  void _onSwipeDownUpdate(double dy) {
    // Tahan animasi snap-back jika masih berjalan
    _dismissSnapController.stop();
    _dismissSnapAnim = null;

    // Berikan rubber-band effect: resistansi meningkat mendekati batas
    final double clamped = dy.clamp(0.0, _dismissMaxDrag);
    final double rubberBand =
        clamped < _dismissMaxDrag ? clamped : _dismissMaxDrag;
    _dismissDragOffset.value = rubberBand;
  }

  void _onSwipeDownEnd(double velocity) {
    final double offset = _dismissDragOffset.value;

    // Jika melewati threshold ATAU velocity ke bawah cukup kencang → dismiss
    if (offset >= _dismissThreshold || velocity > 800) {
      _executeDismiss();
    } else {
      // Snap kembali ke posisi awal dengan spring animation
      _snapBackDismiss();
    }
  }

  void _snapBackDismiss() {
    final double from = _dismissDragOffset.value;
    _dismissSnapController.reset();
    _dismissSnapAnim = Tween<double>(begin: from, end: 0.0).animate(
      CurvedAnimation(
        parent: _dismissSnapController,
        curve: Curves.easeOutCubic,
      ),
    )..addListener(() {
      _dismissDragOffset.value = _dismissSnapAnim!.value;
    });
    _dismissSnapController.forward();
  }

  void _executeDismiss() {
    // Animasikan sisa jarak ke bawah lalu pop
    final double from = _dismissDragOffset.value;
    _dismissSnapController.reset();
    _dismissSnapAnim = Tween<double>(
      begin: from,
      end: MediaQuery.of(context).size.height,
    ).animate(
      CurvedAnimation(
        parent: _dismissSnapController,
        curve: Curves.easeInCubic,
      ),
    )..addListener(() {
      _dismissDragOffset.value = _dismissSnapAnim!.value;
    });
    _dismissSnapController.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        Navigator.pop(context);
      }
    });
    _dismissSnapController.forward();
  }

  // ── Tap navigation ────────────────────────────────────────────────────────

  void _handleTapNavigation(Offset localPosition) {
    if (_isPageZoomed(_currentPage)) {
      final double sw = MediaQuery.of(context).size.width;
      final bool tapCenter =
          localPosition.dx >= sw * 0.25 && localPosition.dx <= sw * 0.75;
      if (tapCenter) setState(() => _showUI = !_showUI);
      return;
    }

    final double sw = MediaQuery.of(context).size.width;
    final bool tapLeft = localPosition.dx < sw * 0.25;
    final bool tapRight = localPosition.dx > sw * 0.75;

    if (!tapLeft && !tapRight) {
      setState(() => _showUI = !_showUI);
      return;
    }

    final bool goNext = _isManga ? tapLeft : tapRight;
    final bool goPrev = _isManga ? tapRight : tapLeft;

    if (goNext) {
      _showTapFlash(isRight: true);
      _navigateNext(); // _navigateNext sudah handle halaman terakhir
    } else if (goPrev) {
      if (_currentPage > 1) {
        _showTapFlash(isRight: false);
        _navigatePrev();
      } else {
        HapticFeedback.lightImpact();
      }
    }
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
      setState(
        () => _bookmarks = decoded.map((e) => Bookmark.fromJson(e)).toList(),
      );
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
        final Uint8List? lb = _getPageBytes(leftPage);
        final Uint8List? rb = _getPageBytes(rightPage);
        if (lb == null && rb == null) {
          _showSnackBar('Halaman belum selesai dimuat', isError: true);
          return;
        }
        final merged = await _mergePages(lb, rb);
        await Gal.putImageBytes(
          merged,
          name:
              '${widget.comic.title}_hal${leftPage}-${rightPage}_${DateTime.now().millisecondsSinceEpoch}.jpg',
        );
        _showSnackBar('Halaman $leftPage–$rightPage disimpan ke galeri');
      } else {
        final Uint8List? bytes = _getPageBytes(_currentPage);
        if (bytes == null) {
          _showSnackBar('Halaman belum selesai dimuat', isError: true);
          return;
        }
        await Gal.putImageBytes(
          bytes,
          name:
              '${widget.comic.title}_hal${_currentPage}_${DateTime.now().millisecondsSinceEpoch}.jpg',
        );
        _showSnackBar('Halaman $_currentPage disimpan ke galeri');
      }
    } catch (e) {
      debugPrint('Save to gallery error: $e');
      _showSnackBar('Gagal menyimpan gambar', isError: true);
    }
  }

  Uint8List? _getPageBytes(int pageNumber) {
    if (_isPdf) return _pdfNotifiers[pageNumber]?.value;
    if (_localPagePaths.isNotEmpty) return _cbzNotifiers[pageNumber]?.value;
    return null;
  }

  Future<Uint8List> _mergePages(
    Uint8List? leftBytes,
    Uint8List? rightBytes,
  ) async {
    final ui.Image? li = await _decodeImage(leftBytes);
    final ui.Image? ri = await _decodeImage(rightBytes);
    final int w = (li?.width ?? ri?.width ?? 800);
    final int h = (li?.height ?? ri?.height ?? 1200);
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, (w * 2).toDouble(), h.toDouble()),
      ui.Paint()..color = const Color(0xFF000000),
    );
    if (li != null) canvas.drawImage(li, ui.Offset.zero, ui.Paint());
    if (ri != null)
      canvas.drawImage(ri, ui.Offset(w.toDouble(), 0), ui.Paint());
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
    if (widget.comic.localPath != null)
      ComicService.closeArchive(widget.comic.localPath!);
    for (final n in _cbzNotifiers.values) n.dispose();
    for (final n in _pdfNotifiers.values) n.dispose();
    for (final n in _zoomNotifiers.values) n.dispose();
    _pageScrollLocked.dispose();
    _dismissDragOffset.dispose();
    _dismissSnapController.dispose();
    _cbzNotifiers.clear();
    _pdfNotifiers.clear();
    _zoomNotifiers.clear();
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
    // Wrap seluruh Scaffold dengan ValueListenableBuilder untuk animasi
    // swipe-down-to-dismiss (translate + fade)
    return ValueListenableBuilder<double>(
      valueListenable: _dismissDragOffset,
      builder: (context, dragOffset, child) {
        // Progress: 0 = normal, 1 = fully dismissed
        final double progress = (dragOffset / _dismissMaxDrag).clamp(0.0, 1.0);
        final double scale = 1.0 - progress * 0.08; // menyusut sedikit
        final double opacity = 1.0 - progress * 0.4;

        return Opacity(
          opacity: opacity.clamp(0.0, 1.0),
          child: Transform(
            alignment: Alignment.topCenter,
            transform:
                Matrix4.identity()
                  ..translate(0.0, dragOffset)
                  ..scale(scale),
            child: child!,
          ),
        );
      },
      child: Scaffold(
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
      ),
    );
  }

  Widget _buildTapZoneFlash(bool isRight) {
    final sw = MediaQuery.of(context).size.width;
    final zw = sw * 0.25;
    return Positioned(
      top: 0,
      bottom: 0,
      left: isRight ? sw - zw : 0,
      width: zw,
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

    return ValueListenableBuilder<bool>(
      valueListenable: _pageScrollLocked,
      builder: (context, locked, _) {
        return PageView.builder(
          scrollDirection:
              _readingMode == ReadingMode.vertical
                  ? Axis.vertical
                  : Axis.horizontal,
          reverse: _isManga,
          controller: _pageController,
          physics:
              locked
                  ? const NeverScrollableScrollPhysics()
                  : const ClampingScrollPhysics(),
          onPageChanged: _onPageChanged,
          itemCount: itemCount,
          itemBuilder: (context, slotIndex) {
            if (!useDual) {
              final int pageNumber = slotIndex + 1;
              return _ZoomPage(
                key: ValueKey('page_$pageNumber'),
                pageNumber: pageNumber,
                zoomNotifier: _zoomNotifierFor(pageNumber),
                pageScrollLocked: _pageScrollLocked,
                isManga: _isManga,
                isVertical: _readingMode == ReadingMode.vertical,
                totalPages: _totalPages,
                onTap: _handleTapNavigation,
                onNavigateNext:
                    pageNumber < _totalPages
                        ? () {
                          HapticFeedback.lightImpact();
                          _navigateNext();
                        }
                        : () {
                          // Halaman terakhir: trigger dialog volume selesai
                          HapticFeedback.mediumImpact();
                          _showVolumeCompleteDialog();
                        },
                onNavigatePrev:
                    pageNumber > 1
                        ? () {
                          HapticFeedback.lightImpact();
                          _navigatePrev();
                        }
                        : null,
                onSwipeDownUpdate: _onSwipeDownUpdate,
                onSwipeDownEnd: _onSwipeDownEnd,
                child: _buildPageContent(slotIndex, primaryColor),
              );
            }

            final int primaryPage = slotIndex * 2 + 1;
            final int leftPage =
                _isManga ? slotIndex * 2 + 2 : slotIndex * 2 + 1;
            final int rightPage =
                _isManga ? slotIndex * 2 + 1 : slotIndex * 2 + 2;

            return _ZoomPage(
              key: ValueKey('dual_$primaryPage'),
              pageNumber: primaryPage,
              zoomNotifier: _zoomNotifierFor(primaryPage),
              pageScrollLocked: _pageScrollLocked,
              isManga: _isManga,
              isVertical: false,
              totalPages: _totalPages,
              onTap: _handleTapNavigation,
              onNavigateNext:
                  primaryPage < _totalPages
                      ? () {
                        HapticFeedback.lightImpact();
                        _navigateNext();
                      }
                      : () {
                        HapticFeedback.mediumImpact();
                        _showVolumeCompleteDialog();
                      },
              onNavigatePrev:
                  primaryPage > 1
                      ? () {
                        HapticFeedback.lightImpact();
                        _navigatePrev();
                      }
                      : null,
              onSwipeDownUpdate: _onSwipeDownUpdate,
              onSwipeDownEnd: _onSwipeDownEnd,
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
            );
          },
        );
      },
    );
  }

  Widget _buildPageContent(int index, Color primaryColor) {
    final int pageNumber = index + 1;

    if (_isPdf) {
      final notifier = _pdfNotifierFor(pageNumber);
      _ensurePdfPageRendered(pageNumber);
      return ValueListenableBuilder<Uint8List?>(
        valueListenable: notifier,
        builder: (context, bytes, _) {
          if (bytes != null) {
            return Center(
              child: Image.memory(
                bytes,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.medium,
                gaplessPlayback: true,
              ),
            );
          }
          return Center(child: CircularProgressIndicator(color: primaryColor));
        },
      );
    }

    if (_localPagePaths.isNotEmpty) {
      final notifier = _cbzNotifierFor(pageNumber);
      _ensureCbzPageDecoded(pageNumber);
      return ValueListenableBuilder<Uint8List?>(
        valueListenable: notifier,
        builder: (context, bytes, _) {
          if (bytes != null) {
            return Center(
              child: Image.memory(
                bytes,
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
          return Center(child: CircularProgressIndicator(color: primaryColor));
        },
      );
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

// ═══════════════════════════════════════════════════════════════════════════
// _VolumeCompleteDialog — ditampilkan saat halaman terakhir selesai
// ═══════════════════════════════════════════════════════════════════════════

class _VolumeCompleteDialog extends StatelessWidget {
  final Comic comic;
  final Comic? nextVolume;
  final VoidCallback onStay;
  final VoidCallback? onNextVolume;

  const _VolumeCompleteDialog({
    required this.comic,
    required this.nextVolume,
    required this.onStay,
    required this.onNextVolume,
  });

  @override
  Widget build(BuildContext context) {
    final Color primaryColor = Theme.of(context).primaryColor;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A).withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // ── Header: ikon selesai ──────────────────────────────────
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 28),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        primaryColor.withValues(alpha: 0.3),
                        primaryColor.withValues(alpha: 0.05),
                      ],
                    ),
                  ),
                  child: Column(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: primaryColor.withValues(alpha: 0.15),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: primaryColor.withValues(alpha: 0.4),
                            width: 1.5,
                          ),
                        ),
                        child: Icon(
                          Icons.auto_stories_rounded,
                          color: primaryColor,
                          size: 32,
                        ),
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        'Volume Selesai!',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        comic.title,
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.white.withValues(alpha: 0.5),
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),

                // ── Next volume card (jika ada) ───────────────────────────
                if (nextVolume != null) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Volume Berikutnya',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Colors.white.withValues(alpha: 0.4),
                            letterSpacing: 0.8,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.05),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.08),
                            ),
                          ),
                          child: Row(
                            children: [
                              // Thumbnail
                              ClipRRect(
                                borderRadius: const BorderRadius.horizontal(
                                  left: Radius.circular(15),
                                ),
                                child: _NextVolumeThumbnail(
                                  thumbnailPath: nextVolume!.thumbnailPath,
                                  primaryColor: primaryColor,
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 14,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        nextVolume!.title,
                                        style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.white,
                                        ),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        nextVolume!.subtitle,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.white.withValues(
                                            alpha: 0.45,
                                          ),
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      if ((nextVolume!.totalPages ?? 0) >
                                          0) ...[
                                        const SizedBox(height: 6),
                                        Text(
                                          '${nextVolume!.totalPages} halaman',
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: primaryColor.withValues(
                                              alpha: 0.8,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ] else ...[
                  // Tidak ada volume berikutnya
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.04),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.check_circle_outline,
                            color: primaryColor,
                            size: 20,
                          ),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Text(
                              'Ini adalah volume terakhir dari seri ini.',
                              style: TextStyle(
                                color: Colors.white60,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],

                // ── Tombol aksi ───────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
                  child: Column(
                    children: [
                      if (nextVolume != null && onNextVolume != null)
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: primaryColor,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            onPressed: onNextVolume,
                            icon: const Icon(Icons.navigate_next, size: 20),
                            label: const Text(
                              'Lanjut ke Volume Berikutnya',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      if (nextVolume != null && onNextVolume != null)
                        const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: TextButton(
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                              side: BorderSide(
                                color: Colors.white.withValues(alpha: 0.12),
                              ),
                            ),
                          ),
                          onPressed: onStay,
                          child: Text(
                            nextVolume != null
                                ? 'Tetap di Sini'
                                : 'Kembali ke Detail',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 14,
                            ),
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
      ),
    );
  }
}

// ── Thumbnail widget untuk next volume ────────────────────────────────────────

class _NextVolumeThumbnail extends StatelessWidget {
  final String? thumbnailPath;
  final Color primaryColor;

  const _NextVolumeThumbnail({
    required this.thumbnailPath,
    required this.primaryColor,
  });

  @override
  Widget build(BuildContext context) {
    const double w = 72.0;
    const double h = 100.0;

    if (thumbnailPath == null || thumbnailPath!.isEmpty) {
      return Container(
        width: w,
        height: h,
        color: Colors.white.withValues(alpha: 0.05),
        child: Icon(Icons.menu_book, color: primaryColor, size: 28),
      );
    }

    // thumbnailPath bisa berupa path lokal atau URL
    if (thumbnailPath!.startsWith('http')) {
      return CachedNetworkImage(
        imageUrl: thumbnailPath!,
        width: w,
        height: h,
        fit: BoxFit.cover,
        placeholder:
            (_, __) => Container(
              width: w,
              height: h,
              color: Colors.white.withValues(alpha: 0.05),
              child: const Center(
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        errorWidget:
            (_, __, ___) => Container(
              width: w,
              height: h,
              color: Colors.white.withValues(alpha: 0.05),
              child: Icon(Icons.menu_book, color: primaryColor, size: 28),
            ),
      );
    }

    return Image.asset(
      thumbnailPath!,
      width: w,
      height: h,
      fit: BoxFit.cover,
      errorBuilder:
          (_, __, ___) => Container(
            width: w,
            height: h,
            color: Colors.white.withValues(alpha: 0.05),
            child: Icon(Icons.menu_book, color: primaryColor, size: 28),
          ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// _FadeSlideRoute — transisi halus antar-volume (fade + slide dari bawah)
// ═══════════════════════════════════════════════════════════════════════════

class _FadeSlideRoute extends PageRouteBuilder {
  final Widget page;

  _FadeSlideRoute({required this.page})
    : super(
        transitionDuration: const Duration(milliseconds: 400),
        reverseTransitionDuration: const Duration(milliseconds: 300),
        pageBuilder: (_, __, ___) => page,
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          );
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0.0, 0.04),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            ),
          );
        },
      );
}

// ═══════════════════════════════════════════════════════════════════════════
// _ZoomPage — widget per-halaman dengan zoom & pan smooth
// ═══════════════════════════════════════════════════════════════════════════

class _ZoomPage extends StatefulWidget {
  final int pageNumber;
  final ValueNotifier<Matrix4> zoomNotifier;
  final ValueNotifier<bool> pageScrollLocked;
  final bool isManga;
  final bool isVertical;
  final int totalPages;
  final void Function(Offset localPosition) onTap;
  final VoidCallback? onNavigateNext;
  final VoidCallback? onNavigatePrev;

  /// Callback swipe-down-to-dismiss: dipanggil HANYA saat tidak zoom
  final void Function(double dy) onSwipeDownUpdate;
  final void Function(double velocity) onSwipeDownEnd;

  final Widget child;

  static const double minScale = 1.0;
  static const double maxScale = 5.0;
  static const double doubleTapScale = 1.5;

  const _ZoomPage({
    super.key,
    required this.pageNumber,
    required this.zoomNotifier,
    required this.pageScrollLocked,
    required this.isManga,
    required this.isVertical,
    required this.totalPages,
    required this.onTap,
    required this.onNavigateNext,
    required this.onNavigatePrev,
    required this.onSwipeDownUpdate,
    required this.onSwipeDownEnd,
    required this.child,
  });

  @override
  State<_ZoomPage> createState() => _ZoomPageState();
}

class _ZoomPageState extends State<_ZoomPage> with TickerProviderStateMixin {
  // State gesture
  Offset _startFocalPoint = Offset.zero;
  double _startScale = 1.0;
  Matrix4 _startMatrix = Matrix4.identity();

  // Edge-pan untuk navigasi via akumulasi overscroll
  double _edgeAccum = 0.0;
  static const double _edgeThreshold = 55.0;

  // Apakah gesture saat ini diidentifikasi sebagai swipe-down
  bool _isSwipeDownGesture = false;

  // Animasi double-tap zoom / snap-back
  late AnimationController _animController;
  Animation<Matrix4>? _anim;

  // Fling inertia
  Ticker? _flingTicker;
  FrictionSimulation? _flingX;
  FrictionSimulation? _flingY;
  Duration? _flingStart;

  static const double _flingMinSpeed = 80.0;
  static const double _flingFriction = 0.015;

  // Ambang vertikal untuk membedakan swipe-down dismiss vs pan normal
  static const double _swipeDownAngleThreshold = 55.0; // derajat

  bool get _isZoomed => widget.zoomNotifier.value.getMaxScaleOnAxis() > 1.05;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
  }

  @override
  void dispose() {
    _flingTicker?.dispose();
    _animController.dispose();
    super.dispose();
  }

  // ── Matrix helpers ────────────────────────────────────────────────────────

  Matrix4 _clamped(Matrix4 m, Size vp) {
    final double s = m.getMaxScaleOnAxis();
    final double tx = m.getTranslation().x;
    final double ty = m.getTranslation().y;
    final double minTx = math.min(0.0, vp.width * (1 - s));
    final double minTy = math.min(0.0, vp.height * (1 - s));
    return Matrix4.identity()
      ..translate(tx.clamp(minTx, 0.0), ty.clamp(minTy, 0.0))
      ..scale(s);
  }

  Set<String> _edges(Size vp) {
    final m = widget.zoomNotifier.value;
    final double s = m.getMaxScaleOnAxis();
    if (s <= 1.05) return {};
    final double tx = m.getTranslation().x;
    final double ty = m.getTranslation().y;
    final double minTx = vp.width * (1 - s);
    final double minTy = vp.height * (1 - s);
    const double eps = 4.0;
    return {
      if (tx >= -eps) 'left',
      if (tx <= minTx + eps) 'right',
      if (ty >= -eps) 'top',
      if (ty <= minTy + eps) 'bottom',
    };
  }

  // ── Gesture handlers ──────────────────────────────────────────────────────

  void _onScaleStart(ScaleStartDetails d) {
    _stopFling();
    _animController.stop();
    _startFocalPoint = d.focalPoint;
    _startMatrix = Matrix4.copy(widget.zoomNotifier.value);
    _startScale = _startMatrix.getMaxScaleOnAxis();
    _edgeAccum = 0.0;
    _isSwipeDownGesture = false;

    if (_isZoomed || d.pointerCount >= 2) {
      widget.pageScrollLocked.value = true;
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final Size vp = MediaQuery.of(context).size;

    if (d.pointerCount >= 2) {
      // Pinch zoom — batalkan swipe-down jika terjadi
      _isSwipeDownGesture = false;
      widget.pageScrollLocked.value = true;

      final double newScale = (_startScale * d.scale).clamp(
        _ZoomPage.minScale,
        _ZoomPage.maxScale,
      );
      final double startTx = _startMatrix.getTranslation().x;
      final double startTy = _startMatrix.getTranslation().y;
      final double tx =
          d.focalPoint.dx -
          (_startFocalPoint.dx - startTx) * (newScale / _startScale);
      final double ty =
          d.focalPoint.dy -
          (_startFocalPoint.dy - startTy) * (newScale / _startScale);
      widget.zoomNotifier.value = _clamped(
        Matrix4.identity()
          ..translate(tx, ty)
          ..scale(newScale),
        vp,
      );
      _edgeAccum = 0.0;
      return;
    }

    // Single-finger
    final double dx = d.focalPointDelta.dx;
    final double dy = d.focalPointDelta.dy;

    if (!_isZoomed) {
      // ── Deteksi swipe-down dismiss ──────────────────────────────────────
      // Hitung apakah gesture ini cukup vertikal ke bawah
      final double totalDy = d.focalPoint.dy - _startFocalPoint.dy;
      final double totalDx = d.focalPoint.dx - _startFocalPoint.dx;

      if (!_isSwipeDownGesture) {
        // Commit ke swipe-down hanya jika sudah bergerak cukup jauh
        // dan arahnya dominan ke bawah
        final double dist = math.sqrt(dx * dx + dy * dy);
        if (dist > 8) {
          final double angle =
              math.atan2(totalDy, totalDx.abs()) * (180 / math.pi);
          if (totalDy > 0 && angle > _swipeDownAngleThreshold) {
            _isSwipeDownGesture = true;
            // Kunci PageView supaya tidak slide horizontal
            widget.pageScrollLocked.value = true;
          }
        }
      }

      if (_isSwipeDownGesture && totalDy > 0) {
        widget.onSwipeDownUpdate(totalDy);
        return;
      }

      // Jika bukan swipe-down, biarkan PageView menangani
      return;
    }

    // ── Single-finger pan saat zoom aktif ────────────────────────────────
    widget.pageScrollLocked.value = true;

    final double s = widget.zoomNotifier.value.getMaxScaleOnAxis();
    final double curTx = widget.zoomNotifier.value.getTranslation().x;
    final double curTy = widget.zoomNotifier.value.getTranslation().y;
    widget.zoomNotifier.value = _clamped(
      Matrix4.identity()
        ..translate(curTx + dx, curTy + dy)
        ..scale(s),
      vp,
    );

    // Akumulasi edge-pan
    final edges = _edges(vp);
    if (!widget.isVertical) {
      if ((dx < 0 && edges.contains('right')) ||
          (dx > 0 && edges.contains('left'))) {
        _edgeAccum += dx.abs();
      } else {
        _edgeAccum = 0.0;
      }
    } else {
      if ((dy < 0 && edges.contains('bottom')) ||
          (dy > 0 && edges.contains('top'))) {
        _edgeAccum += dy.abs();
      } else {
        _edgeAccum = 0.0;
      }
    }
  }

  void _onScaleEnd(ScaleEndDetails d) {
    final Size vp = MediaQuery.of(context).size;

    // Selesaikan swipe-down
    if (_isSwipeDownGesture) {
      _isSwipeDownGesture = false;
      widget.pageScrollLocked.value = false;
      final double vy = d.velocity.pixelsPerSecond.dy;
      widget.onSwipeDownEnd(vy);
      return;
    }

    if (widget.zoomNotifier.value.getMaxScaleOnAxis() < _ZoomPage.minScale) {
      _animateTo(
        Matrix4.identity(),
        onComplete: () {
          widget.pageScrollLocked.value = false;
        },
      );
      return;
    }

    if (_isZoomed && _edgeAccum >= _edgeThreshold) {
      final edges = _edges(vp);
      if (!widget.isVertical) {
        final bool wantsNext = edges.contains('right');
        final bool wantsPrev = edges.contains('left');
        final bool goNext = widget.isManga ? wantsPrev : wantsNext;
        final bool goPrev = widget.isManga ? wantsNext : wantsPrev;
        if (goNext)
          widget.onNavigateNext?.call();
        else if (goPrev)
          widget.onNavigatePrev?.call();
        else
          HapticFeedback.lightImpact();
      } else {
        if (edges.contains('bottom'))
          widget.onNavigateNext?.call();
        else if (edges.contains('top'))
          widget.onNavigatePrev?.call();
        else
          HapticFeedback.lightImpact();
      }
      _edgeAccum = 0.0;
      if (!_isZoomed) widget.pageScrollLocked.value = false;
      return;
    }
    _edgeAccum = 0.0;

    if (_isZoomed) {
      final Offset vel = d.velocity.pixelsPerSecond;
      final double speed = vel.distance;
      if (speed > _flingMinSpeed) {
        _startFling(vel, vp);
        return;
      }
    }

    if (!_isZoomed) widget.pageScrollLocked.value = false;
  }

  // ── Fling helpers ─────────────────────────────────────────────────────────

  void _stopFling() {
    _flingTicker?.stop();
    _flingX = null;
    _flingY = null;
    _flingStart = null;
  }

  void _startFling(Offset vel, Size vp) {
    final double curTx = widget.zoomNotifier.value.getTranslation().x;
    final double curTy = widget.zoomNotifier.value.getTranslation().y;

    _flingX = FrictionSimulation(_flingFriction, curTx, vel.dx);
    _flingY = FrictionSimulation(_flingFriction, curTy, vel.dy);
    _flingStart = null;

    _flingTicker?.dispose();
    _flingTicker = createTicker((elapsed) {
      _flingStart ??= elapsed;
      final double t = (elapsed - _flingStart!).inMicroseconds / 1e6;
      final double nx = _flingX!.x(t);
      final double ny = _flingY!.x(t);
      final double vx = _flingX!.dx(t);
      final double vy = _flingY!.dx(t);

      final double s = widget.zoomNotifier.value.getMaxScaleOnAxis();
      widget.zoomNotifier.value = _clamped(
        Matrix4.identity()
          ..translate(nx, ny)
          ..scale(s),
        vp,
      );

      final bool stopped = vx.abs() < 1.0 && vy.abs() < 1.0;
      final bool atEdge = _isAtAllRelevantEdges(vp, vx, vy);
      if (stopped || atEdge) {
        _stopFling();
      }
    });
    _flingTicker!.start();
  }

  bool _isAtAllRelevantEdges(Size vp, double vx, double vy) {
    final edges = _edges(vp);
    final bool blockedX =
        (vx > 0 && edges.contains('left')) ||
        (vx < 0 && edges.contains('right')) ||
        vx.abs() < 1.0;
    final bool blockedY =
        (vy > 0 && edges.contains('top')) ||
        (vy < 0 && edges.contains('bottom')) ||
        vy.abs() < 1.0;
    return blockedX && blockedY;
  }

  void _onDoubleTapDown(TapDownDetails d) {
    _stopFling();
    final Size vp = MediaQuery.of(context).size;
    if (_isZoomed) {
      _animateTo(
        Matrix4.identity(),
        onComplete: () {
          widget.pageScrollLocked.value = false;
        },
      );
    } else {
      const double s = _ZoomPage.doubleTapScale;
      final double tx = (vp.width / 2) - d.localPosition.dx * s;
      final double ty = (vp.height / 2) - d.localPosition.dy * s;
      widget.pageScrollLocked.value = true;
      _animateTo(
        _clamped(
          Matrix4.identity()
            ..translate(tx, ty)
            ..scale(s),
          vp,
        ),
      );
    }
  }

  void _animateTo(Matrix4 target, {VoidCallback? onComplete}) {
    final Matrix4 from = Matrix4.copy(widget.zoomNotifier.value);
    _animController.stop();
    _anim = Matrix4Tween(begin: from, end: target).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic),
    )..addListener(() {
      if (mounted) widget.zoomNotifier.value = _anim!.value;
    });

    if (onComplete != null) {
      _animController.addStatusListener((status) {
        if (status == AnimationStatus.completed ||
            status == AnimationStatus.dismissed) {
          onComplete();
        }
      });
    }

    _animController
      ..reset()
      ..forward();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      gestures: {
        _AllowMultipleScaleRecognizer:
            GestureRecognizerFactoryWithHandlers<_AllowMultipleScaleRecognizer>(
              () => _AllowMultipleScaleRecognizer(debugOwner: this),
              (instance) {
                instance
                  ..onStart = _onScaleStart
                  ..onUpdate = _onScaleUpdate
                  ..onEnd = _onScaleEnd;
              },
            ),
        TapGestureRecognizer: GestureRecognizerFactoryWithHandlers<
          TapGestureRecognizer
        >(() => TapGestureRecognizer(debugOwner: this), (instance) {
          instance.onTapUp = (details) => widget.onTap(details.localPosition);
        }),
        DoubleTapGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<DoubleTapGestureRecognizer>(
              () => DoubleTapGestureRecognizer(debugOwner: this),
              (instance) {
                instance.onDoubleTapDown = _onDoubleTapDown;
                instance.onDoubleTap = () {};
              },
            ),
      },
      child: ValueListenableBuilder<Matrix4>(
        valueListenable: widget.zoomNotifier,
        builder:
            (context, matrix, child) =>
                Transform(transform: matrix, child: child),
        child: widget.child,
      ),
    );
  }
}
