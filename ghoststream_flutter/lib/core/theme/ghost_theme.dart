import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'ghost_colors.dart';

TextStyle ghostMono({
  double fontSize = 14,
  FontWeight fontWeight = FontWeight.normal,
  Color? color,
}) {
  return GoogleFonts.robotoMono(
    fontSize: fontSize,
    fontWeight: fontWeight,
    color: color,
  );
}

ThemeData ghostDarkTheme() {
  const c = GhostColors.darkColors;
  return ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: c.pageBase,
    colorScheme: ColorScheme.dark(
      primary: c.accentPurple,
      secondary: c.accentTeal,
      surface: c.background,
      error: c.redError,
    ),
    useMaterial3: true,
  );
}

ThemeData ghostLightTheme() {
  const c = GhostColors.lightColors;
  return ThemeData(
    brightness: Brightness.light,
    scaffoldBackgroundColor: c.pageBase,
    colorScheme: ColorScheme.light(
      primary: c.accentPurple,
      secondary: c.accentTeal,
      surface: c.background,
      error: c.redError,
    ),
    useMaterial3: true,
  );
}
