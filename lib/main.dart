import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'pages/library_page.dart';

void main() {
  runApp(const CodexApp());
}

class CodexApp extends StatelessWidget {
  const CodexApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Modern Color Palette
    const Color primaryColor = Color(0xFF4B5BAB); // Medium blueish indigo
    const Color accentColor = Color(0xFFCFFF70); // Bright lime green
    const Color surfaceColor = Color(
      0xFF1A2142,
    ); // Darker blueish indigo background

    return MaterialApp(
      title: 'Codex',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        primaryColor: primaryColor,
        scaffoldBackgroundColor: surfaceColor,
        colorScheme: ColorScheme.fromSeed(
          seedColor: primaryColor,
          brightness: Brightness.dark,
          primary: primaryColor,
          secondary: accentColor,
          surface: surfaceColor,
          onSurface: Colors.white,
          onPrimary: Colors.white,
          onSecondary: Colors.black,
        ),
        textTheme: GoogleFonts.splineSansTextTheme(ThemeData.dark().textTheme),
      ),
      home: const LibraryPage(),
    );
  }
}
