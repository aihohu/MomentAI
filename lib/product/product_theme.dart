import 'package:flutter/material.dart';

abstract final class ProductColors {
  static const paper = Color(0xFFF7F8F5);
  static const surface = Color(0xFFFFFFFF);
  static const ink = Color(0xFF1B211D);
  static const mutedInk = Color(0xFF667069);
  static const forest = Color(0xFF1F6A4A);
  static const forestSoft = Color(0xFFE8F2EC);
  static const vermilion = Color(0xFFB64D35);
  static const amber = Color(0xFF9A681F);
  static const amberSoft = Color(0xFFFFEECF);
  static const line = Color(0xFFE3E5DF);
}

ThemeData buildProductTheme() {
  final colorScheme =
      ColorScheme.fromSeed(
        seedColor: ProductColors.forest,
        brightness: Brightness.light,
        surface: ProductColors.surface,
      ).copyWith(
        primary: ProductColors.forest,
        error: ProductColors.vermilion,
        onSurface: ProductColors.ink,
        outline: ProductColors.line,
      );
  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: ProductColors.paper,
    fontFamilyFallback: const ['PingFang SC', 'Heiti SC'],
    appBarTheme: const AppBarTheme(
      backgroundColor: ProductColors.paper,
      foregroundColor: ProductColors.ink,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      elevation: 0,
    ),
    cardTheme: CardThemeData(
      color: ProductColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: ProductColors.line),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(44, 54),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(44, 50),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        side: const BorderSide(color: ProductColors.line),
      ),
    ),
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: ProductColors.surface,
      indicatorColor: ProductColors.forestSoft,
      labelTextStyle: WidgetStatePropertyAll(
        TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
      height: 70,
    ),
    dividerTheme: const DividerThemeData(color: ProductColors.line),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: ProductColors.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: ProductColors.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: ProductColors.line),
      ),
    ),
  );
}
