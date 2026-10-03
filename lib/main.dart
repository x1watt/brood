import 'package:flutter/material.dart';

import 'ui/start_screen.dart';

void main() {
  runApp(const BroodApp());
}

/// Black and neutral greys throughout; the only colors are the game's own
/// (resources, health, player relations).
ThemeData _theme() {
  const text = Color(0xFFE8E8E8);
  const line = Color(0xFF2A2A2A);
  final base = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    colorScheme: const ColorScheme.dark(
      primary: Colors.white,
      onPrimary: Colors.black,
      secondary: Color(0xFFBDBDBD),
      onSecondary: Colors.black,
      secondaryContainer: Color(0xFF2E2E2E),
      onSecondaryContainer: Colors.white,
      surface: Colors.black,
      onSurface: text,
      surfaceContainerLowest: Colors.black,
      surfaceContainerLow: Color(0xFF0A0A0A),
      surfaceContainer: Color(0xFF0E0E0E),
      surfaceContainerHigh: Color(0xFF141414),
      surfaceContainerHighest: Color(0xFF1A1A1A),
      outline: Color(0xFF444444),
      outlineVariant: line,
      error: Color(0xFFFF6B5E),
    ),
    scaffoldBackgroundColor: Colors.black,
    canvasColor: Colors.black,
    dividerColor: line,
  );
  return base.copyWith(
    listTileTheme: const ListTileThemeData(selectedColor: Colors.white, selectedTileColor: Color(0xFF1C1C1C), textColor: text),
    dialogTheme: const DialogThemeData(
      backgroundColor: Color(0xFF0E0E0E),
      shape: RoundedRectangleBorder(side: BorderSide(color: line), borderRadius: BorderRadius.all(Radius.circular(6))),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: Color(0xFF1A1A1A),
      contentTextStyle: TextStyle(color: text),
      behavior: SnackBarBehavior.floating,
      width: 360,
    ),
    tooltipTheme: const TooltipThemeData(
      decoration: BoxDecoration(color: Color(0xFF1A1A1A), border: Border.fromBorderSide(BorderSide(color: line))),
      textStyle: TextStyle(color: text, fontSize: 12),
    ),
  );
}

class BroodApp extends StatelessWidget {
  const BroodApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Brood',
      debugShowCheckedModeBanner: false,
      theme: _theme(),
      home: const StartScreen(),
    );
  }
}
