import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../services/reading_history_service.dart';

class SettingPage extends StatefulWidget {
  const SettingPage({super.key});

  @override
  State<SettingPage> createState() => _SettingPageState();
}

class _SettingPageState extends State<SettingPage> {
  bool _isExporting = false;
  bool _isImporting = false;

  // ─── Export ───────────────────────────────────────────────────────────────

  Future<void> _exportHistory() async {
    setState(() => _isExporting = true);

    try {
      final history = await ReadingHistoryService.loadHistory();

      if (history.isEmpty) {
        _showSnackBar(
          'Tidak ada riwayat baca untuk diekspor',
          icon: Icons.info_outline,
          color: Colors.orange,
        );
        return;
      }

      final exportData = {
        'exported_at': DateTime.now().toIso8601String(),
        'version': 1,
        'count': history.length,
        'entries': history.map((e) => e.toJson()).toList(),
      };

      final jsonString = const JsonEncoder.withIndent('  ').convert(exportData);

      final dir = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .replaceAll('.', '-')
          .substring(0, 19);
      final fileName = 'reading_history_$timestamp.json';
      final filePath = p.join(dir.path, fileName);

      await File(filePath).writeAsString(jsonString);

      if (!mounted) return;
      await _showExportSuccessDialog(filePath, history.length);
    } catch (e) {
      _showSnackBar(
        'Gagal mengekspor: $e',
        icon: Icons.error_outline,
        color: Colors.red,
      );
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  // ─── Import ───────────────────────────────────────────────────────────────

  Future<void> _importHistory() async {
    final confirmed = await _showImportConfirmDialog();
    if (!confirmed) return;

    setState(() => _isImporting = true);

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) return;

      final filePath = result.files.first.path;
      if (filePath == null) return;

      final file = File(filePath);
      if (!file.existsSync()) {
        _showSnackBar(
          'File tidak ditemukan',
          icon: Icons.error_outline,
          color: Colors.red,
        );
        return;
      }

      final jsonString = await file.readAsString();
      final Map<String, dynamic> decoded = jsonDecode(jsonString);

      if (!decoded.containsKey('entries') || decoded['version'] != 1) {
        _showSnackBar(
          'Format file tidak valid. Pastikan file berasal dari ekspor aplikasi ini.',
          icon: Icons.warning_amber_rounded,
          color: Colors.orange,
        );
        return;
      }

      final List entriesJson = decoded['entries'] as List;
      final importedEntries =
          entriesJson
              .map(
                (e) => ReadingHistoryEntry.fromJson(e as Map<String, dynamic>),
              )
              .toList();

      int importedCount = 0;
      for (final entry in importedEntries) {
        await ReadingHistoryService.saveEntry(entry);
        importedCount++;
      }

      if (!mounted) return;
      _showSnackBar(
        '$importedCount riwayat berhasil diimpor',
        icon: Icons.check_circle_outline,
        color: Colors.green,
      );
    } on FormatException {
      _showSnackBar(
        'File JSON tidak valid atau rusak',
        icon: Icons.error_outline,
        color: Colors.red,
      );
    } catch (e) {
      _showSnackBar(
        'Gagal mengimpor: $e',
        icon: Icons.error_outline,
        color: Colors.red,
      );
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  // ─── Clear History ────────────────────────────────────────────────────────

  Future<void> _clearHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1E1E2E),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: const Text(
              'Hapus Semua Riwayat?',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            content: const Text(
              'Semua riwayat baca akan dihapus secara permanen. Tindakan ini tidak dapat dibatalkan.',
              style: TextStyle(color: Colors.white60, height: 1.5),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text(
                  'Batal',
                  style: TextStyle(color: Colors.white54),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: TextButton.styleFrom(foregroundColor: Colors.red),
                child: const Text('Hapus Semua'),
              ),
            ],
          ),
    );

    if (confirmed != true) return;
    await ReadingHistoryService.clearHistory();
    if (!mounted) return;
    _showSnackBar(
      'Riwayat baca berhasil dihapus',
      icon: Icons.delete_outline,
      color: Colors.red,
    );
  }

  // ─── Dialogs & Snackbar ───────────────────────────────────────────────────

  Future<void> _showExportSuccessDialog(String filePath, int count) async {
    await showDialog(
      context: context,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1E1E2E),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: Row(
              children: [
                Icon(
                  Icons.check_circle,
                  color: Colors.green.shade400,
                  size: 22,
                ),
                const SizedBox(width: 10),
                const Text(
                  'Ekspor Berhasil',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$count riwayat berhasil diekspor.',
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Lokasi file:',
                  style: TextStyle(color: Colors.white38, fontSize: 12),
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    filePath,
                    style: const TextStyle(
                      color: Colors.white60,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text(
                  'OK',
                  style: TextStyle(color: Color(0xFF7B8FE8)),
                ),
              ),
            ],
          ),
    );
  }

  Future<bool> _showImportConfirmDialog() async {
    final result = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1E1E2E),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: const Text(
              'Impor Riwayat Baca',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            content: const Text(
              'Pilih file JSON hasil ekspor. Riwayat yang sudah ada akan digabungkan — entri dengan ID yang sama akan diperbarui.',
              style: TextStyle(color: Colors.white60, height: 1.5),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text(
                  'Batal',
                  style: TextStyle(color: Colors.white54),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text(
                  'Pilih File',
                  style: TextStyle(color: Color(0xFF7B8FE8)),
                ),
              ),
            ],
          ),
    );
    return result ?? false;
  }

  void _showSnackBar(
    String message, {
    required IconData icon,
    required Color color,
  }) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(icon, color: Colors.white, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(message, style: const TextStyle(color: Colors.white)),
            ),
          ],
        ),
        backgroundColor: color.withValues(alpha: 0.9),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final Color accentColor = Theme.of(context).colorScheme.secondary;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Pengaturan'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          // ── Section: Riwayat Baca ─────────────────────────────────────
          _buildSectionHeader('Riwayat Baca', Icons.history_rounded),
          const SizedBox(height: 8),
          _buildCard(
            children: [
              _buildTile(
                icon: Icons.upload_file_rounded,
                iconColor: accentColor,
                title: 'Ekspor Riwayat',
                subtitle: 'Simpan riwayat baca ke file JSON',
                trailing:
                    _isExporting
                        ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                        : const Icon(
                          Icons.chevron_right,
                          color: Colors.white24,
                        ),
                onTap: _isExporting ? null : _exportHistory,
              ),
              _buildDivider(),
              _buildTile(
                icon: Icons.download_rounded,
                iconColor: const Color(0xFF7B8FE8),
                title: 'Impor Riwayat',
                subtitle: 'Muat riwayat dari file JSON',
                trailing:
                    _isImporting
                        ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                        : const Icon(
                          Icons.chevron_right,
                          color: Colors.white24,
                        ),
                onTap: _isImporting ? null : _importHistory,
              ),
              _buildDivider(),
              _buildTile(
                icon: Icons.delete_sweep_rounded,
                iconColor: Colors.red.shade400,
                title: 'Hapus Semua Riwayat',
                subtitle: 'Hapus seluruh riwayat baca secara permanen',
                trailing: const Icon(
                  Icons.chevron_right,
                  color: Colors.white24,
                ),
                onTap: _clearHistory,
              ),
            ],
          ),

          const SizedBox(height: 24),

          // ── Section: Info ─────────────────────────────────────────────
          _buildSectionHeader('Informasi', Icons.info_outline_rounded),
          const SizedBox(height: 8),
          _buildCard(
            children: [
              _buildTile(
                icon: Icons.description_outlined,
                iconColor: Colors.white38,
                title: 'Format Ekspor',
                subtitle: 'JSON (kompatibel antar perangkat)',
                onTap: null,
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ─── Widget Helpers ───────────────────────────────────────────────────────

  Widget _buildSectionHeader(String title, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 4),
      child: Row(
        children: [
          Icon(icon, size: 14, color: Colors.white38),
          const SizedBox(width: 6),
          Text(
            title.toUpperCase(),
            style: const TextStyle(
              fontSize: 11,
              color: Colors.white38,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCard({required List<Widget> children}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(children: children),
    );
  }

  Widget _buildTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: iconColor, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: onTap == null ? Colors.white38 : Colors.white,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(fontSize: 12, color: Colors.white38),
                  ),
                ],
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 8), trailing],
          ],
        ),
      ),
    );
  }

  Widget _buildDivider() {
    return Divider(
      height: 1,
      indent: 68,
      endIndent: 0,
      color: Colors.white.withValues(alpha: 0.05),
    );
  }
}
