# 📚 Codex

A smooth, polished comic and manga reader for Android, built with Flutter.

Codex supports CBZ, ZIP, and PDF formats with a focus on performance and reading comfort — featuring lazy loading, smart caching, dual-page mode, and full manga (RTL) support.

---

## ✨ Features

- **Multiple Format Support** — CBZ, CBR, ZIP, and PDF
- **Smooth Zoom & Navigation** — Instagram-style pinch-to-zoom with edge-pan page switching
- **Series Grouping** — Automatically groups related comics into series
- **Reading Progress Tracking** — Picks up right where you left off
- **Dual-Page Mode** — Side-by-side pages for a true book feel
- **Manga Mode** — Right-to-left reading support
- **Bookmarks** — Mark and revisit your favorite pages
- **Save to Gallery** — Export any page directly to your device gallery
- **Thumbnail Generation** — Fast cover previews for your library
- **Smart Caching** — Lazy archive loading with per-page cache and prefetch/eviction logic

---

<!-- ## 📸 Screenshots

<!-- > Coming soon -->

--- -->

## 🚀 Getting Started

### Prerequisites

- [Flutter](https://flutter.dev/docs/get-started/install) SDK `^3.7.2`
- Android SDK (API 21+)

### Installation

```bash
# Clone the repository
git clone https://github.com/oswldc/codex.git
cd codex

# Install dependencies
flutter pub get

# Run the app
flutter run
```

> **Note:** A full rebuild (not hot reload) is required after any changes to `AndroidManifest.xml`.

---

## 🏗️ Architecture

The app is organized around two core files:

| File                 | Responsibility                                                       |
| -------------------- | -------------------------------------------------------------------- |
| `comic_service.dart` | File handling, archive/PDF management, thumbnail generation, caching |
| `reader_page.dart`   | Reader UI, gestures, zoom, navigation, reading modes                 |

### Key Implementation Details

- **Zoom** — Custom `_InstagramZoomPage` widget using raw `GestureDetector` and direct `Matrix4` manipulation; per-page `ValueNotifier<Uint8List?>` to minimize rebuilds
- **Prefetch Strategy** — Asymmetric: 3 pages forward, 1 page backward
- **CBZ/ZIP** — Archive opened once into a shared `_openArchives` static cache; pages read from cache via `getPageBytes`
- **CBR** — Falls back from ZIP to RAR decoding using the `archive` package's `RarDecoder`
- **PDF** — Caches open `PdfDocument` instances; page-level render cache keyed by path/page/scale with background prefetch and eviction
- **Cache Eviction** — ±10 page radius for both PDF and CBZ lazy caches
- **Impeller** — Disabled in `AndroidManifest.xml` to avoid an image inversion bug on physical Android devices (reverts to Skia renderer)

---

## 📦 Dependencies

| Package                  | Version | Purpose                      |
| ------------------------ | ------- | ---------------------------- |
| `archive`                | ^3.6.1  | CBZ / CBR archive reading    |
| `pdfx`                   | ^2.6.0  | PDF rendering                |
| `file_picker`            | ^8.1.4  | File selection               |
| `shared_preferences`     | ^2.5.3  | Reading progress persistence |
| `path_provider`          | ^2.1.3  | Local storage paths          |
| `gal`                    | latest  | Save pages to gallery        |
| `flutter_launcher_icons` | ^0.13.1 | App icon generation          |

---

## 🗺️ Roadmap

- [ ] Cloud storage sync (Google Drive / Dropbox)
- [ ] Custom reading themes (sepia, dark, AMOLED)
- [ ] Chapter auto-detection
- [ ] Webtoon (vertical strip) mode
- [ ] Reading statistics

---

## 🤝 Contributing

Contributions are welcome! Please open an issue first to discuss what you'd like to change.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

---

## 📄 License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.

---

<p align="center">Just my personal project for my personal use</p>
