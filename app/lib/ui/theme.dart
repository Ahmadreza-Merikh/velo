import 'package:flutter/material.dart';

class VeloColors {
  static const Color background = Color(0xFF0B1020);
  static const Color surface = Color(0xFF141A2E);
  static const Color surfaceHigh = Color(0xFF1D2540);
  static const Color idle = Color(0xFF3C4767);
  static const Color accent = Color(0xFF3FA9F5);
  static const Color connected = Color(0xFF2ED573);
  static const Color warning = Color(0xFFFFB020);
  static const Color danger = Color(0xFFFF4D5E);
  static const Color textPrimary = Color(0xFFF2F5FF);
  static const Color textMuted = Color(0xFF8C98BC);
  static const Color hairline = Color(0x22FFFFFF);
}

ThemeData veloTheme() {
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: const ColorScheme.dark(
      primary: VeloColors.accent,
      secondary: VeloColors.connected,
      surface: VeloColors.surface,
      error: VeloColors.danger,
      onPrimary: Colors.white,
      onSecondary: Colors.black,
      onSurface: VeloColors.textPrimary,
      onError: Colors.white,
    ),
    scaffoldBackgroundColor: VeloColors.background,
    canvasColor: VeloColors.background,
    dividerColor: VeloColors.hairline,
    textTheme: const TextTheme(
      titleLarge: TextStyle(
        color: VeloColors.textPrimary,
        fontSize: 20,
        fontWeight: FontWeight.w600,
      ),
      titleMedium: TextStyle(
        color: VeloColors.textPrimary,
        fontSize: 16,
        fontWeight: FontWeight.w600,
      ),
      bodyMedium: TextStyle(color: VeloColors.textPrimary, fontSize: 14),
      bodySmall: TextStyle(color: VeloColors.textMuted, fontSize: 12),
    ),
  );
}

InputDecoration veloField(String hint) {
  return InputDecoration(
    hintText: hint,
    isDense: true,
    filled: true,
    fillColor: VeloColors.surfaceHigh,
    hintStyle: const TextStyle(color: VeloColors.textMuted, fontSize: 13),
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    border: const OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(12)),
      borderSide: BorderSide.none,
    ),
    enabledBorder: const OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(12)),
      borderSide: BorderSide.none,
    ),
    focusedBorder: const OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(12)),
      borderSide: BorderSide(color: VeloColors.accent),
    ),
  );
}

AppBar veloAppBar(String title, {Widget? leading, List<Widget>? actions}) {
  return AppBar(
    title: Text(title),
    leading: leading,
    actions: actions,
    centerTitle: true,
    elevation: 0,
    backgroundColor: Colors.transparent,
    foregroundColor: VeloColors.textPrimary,
    surfaceTintColor: Colors.transparent,
  );
}
