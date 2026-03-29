import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

class ExifAwareImage extends StatefulWidget {
  final String path;
  final BoxFit fit;
  final Widget? errorWidget;

  const ExifAwareImage({
    super.key,
    required this.path,
    this.fit = BoxFit.cover,
    this.errorWidget,
  });

  @override
  State<ExifAwareImage> createState() => _ExifAwareImageState();
}

class _ExifAwareImageState extends State<ExifAwareImage> {
  Uint8List? _correctedBytes;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadCorrected();
  }

  Future<void> _loadCorrected() async {
    try {
      final bytes = await File(widget.path).readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return;

      // img.decodeImage sudah otomatis apply EXIF orientation
      final fixed = img.encodeJpg(decoded);
      if (mounted) {
        setState(() {
          _correctedBytes = Uint8List.fromList(fixed);
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    if (_correctedBytes == null) {
      return widget.errorWidget ??
          const Icon(Icons.broken_image, color: Colors.white24);
    }

    return Image.memory(_correctedBytes!, fit: widget.fit);
  }
}
