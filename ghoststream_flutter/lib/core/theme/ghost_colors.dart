import 'package:flutter/material.dart';

@immutable
class GhostColors {
  final Color pageBase;
  final Color pageGlowA;
  final Color pageGlowB;
  final Color background;
  final Color surface;
  final Color card;
  final Color border;
  final Color accentPurple;
  final Color accentTeal;
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final Color overlayBackdrop;
  final Color sheetGradStart;
  final Color sheetGradEnd;
  final Color logsSheetStart;
  final Color logsSheetEnd;
  final Color settSheetStart;
  final Color settSheetEnd;
  final Color adminSheetStart;
  final Color adminSheetEnd;
  final Color dnsSheetStart;
  final Color dnsSheetEnd;
  final Color appsSheetStart;
  final Color appsSheetEnd;
  final Color routesSheetStart;
  final Color routesSheetEnd;
  final Color addServerSheetStart;
  final Color addServerSheetEnd;
  final Color miniToastBg;
  final Color shadowColor;
  final Color greenConnected;
  final Color redError;
  final Color yellowWarning;
  final Color blueDebug;
  final Color connectingBlue;
  final Color dangerRose;
  final Color pingGood;
  final Color pingMid;
  final Color pingHigh;
  final Color statDl;
  final Color statUl;
  final Color statSe;
  final Color statPk;
  final Color adminHeroGradStart;
  final Color adminHeroGradMid;
  final Color adminHeroGradEnd;

  const GhostColors({
    required this.pageBase,
    required this.pageGlowA,
    required this.pageGlowB,
    required this.background,
    required this.surface,
    required this.card,
    required this.border,
    required this.accentPurple,
    required this.accentTeal,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.overlayBackdrop,
    required this.sheetGradStart,
    required this.sheetGradEnd,
    required this.logsSheetStart,
    required this.logsSheetEnd,
    required this.settSheetStart,
    required this.settSheetEnd,
    required this.adminSheetStart,
    required this.adminSheetEnd,
    required this.dnsSheetStart,
    required this.dnsSheetEnd,
    required this.appsSheetStart,
    required this.appsSheetEnd,
    required this.routesSheetStart,
    required this.routesSheetEnd,
    required this.addServerSheetStart,
    required this.addServerSheetEnd,
    required this.miniToastBg,
    required this.shadowColor,
    required this.greenConnected,
    required this.redError,
    required this.yellowWarning,
    required this.blueDebug,
    required this.connectingBlue,
    required this.dangerRose,
    required this.pingGood,
    required this.pingMid,
    required this.pingHigh,
    required this.statDl,
    required this.statUl,
    required this.statSe,
    required this.statPk,
    required this.adminHeroGradStart,
    required this.adminHeroGradMid,
    required this.adminHeroGradEnd,
  });

  Color get accent => accentPurple;
  Color get accent2 => accentTeal;
  Color get text => textPrimary;
  Color get error => redError;
  Color get connecting => connectingBlue;
  Color get background2 => surface;
  Color get cardBg => card;
  Color get cardBorder => border;
  Color get statDownload => statDl;
  Color get statUpload => statUl;
  Color get statSession => statSe;
  Color get statPackets => statPk;
  Color get accentPurpleLight => Color.lerp(accentPurple, Colors.white, 0.3)!;
  Color get logsSheetGradStart => logsSheetStart;
  Color get logsSheetGradEnd => logsSheetEnd;
  Color get settSheetGradStart => settSheetStart;
  Color get settSheetGradEnd => settSheetEnd;
  Color get adminSheetGradStart => adminSheetStart;
  Color get adminSheetGradEnd => adminSheetEnd;

  static const darkColors = GhostColors(
    pageBase: Color(0xFF090B16),
    pageGlowA: Color(0x387C6AF7),
    pageGlowB: Color(0x1F22D3A0),
    background: Color(0xFF0D0D1C),
    surface: Color(0xFF13132A),
    card: Color(0x0DFFFFFF),
    border: Color(0x17FFFFFF),
    accentPurple: Color(0xFF7C6AF7),
    accentTeal: Color(0xFF22D3A0),
    textPrimary: Color(0xFFF0EFFF),
    textSecondary: Color(0x99F0EFFF),
    textTertiary: Color(0x59F0EFFF),
    overlayBackdrop: Color(0xCC050412),
    sheetGradStart: Color(0xFF1E1F3A),
    sheetGradEnd: Color(0xFF101122),
    logsSheetStart: Color(0xFF141E34),
    logsSheetEnd: Color(0xFF0C101E),
    settSheetStart: Color(0xFF1C1534),
    settSheetEnd: Color(0xFF0F0E1F),
    adminSheetStart: Color(0xFF191B2C),
    adminSheetEnd: Color(0xFF11121F),
    dnsSheetStart: Color(0xFF122326),
    dnsSheetEnd: Color(0xFF0A1218),
    appsSheetStart: Color(0xFF16142D),
    appsSheetEnd: Color(0xFF0B0D1C),
    routesSheetStart: Color(0xFF18152E),
    routesSheetEnd: Color(0xFF0B0E1D),
    addServerSheetStart: Color(0xFF1C1836),
    addServerSheetEnd: Color(0xFF0E101F),
    miniToastBg: Color(0xF0121322),
    shadowColor: Color(0x6B000000),
    greenConnected: Color(0xFF22D3A0),
    redError: Color(0xFFFF5252),
    yellowWarning: Color(0xFFFFD740),
    blueDebug: Color(0xFF60A5FA),
    connectingBlue: Color(0xFF60A5FA),
    dangerRose: Color(0xFFFB7185),
    pingGood: Color(0xFF34D399),
    pingMid: Color(0xFFFBBF24),
    pingHigh: Color(0xFFFB7185),
    statDl: Color(0xFF06B6D4),
    statUl: Color(0xFF8B5CF6),
    statSe: Color(0xFFFB923C),
    statPk: Color(0xFF22D3A0),
    adminHeroGradStart: Color(0x387C6AF7),
    adminHeroGradMid: Color(0xF51A1C34),
    adminHeroGradEnd: Color(0xFA0B0F1C),
  );

  static const lightColors = GhostColors(
    pageBase: Color(0xFFEEF2FF),
    pageGlowA: Color(0x296B57F6),
    pageGlowB: Color(0x1C0F9F85),
    background: Color(0xFFF7F8FF),
    surface: Color(0xFFEDF0FF),
    card: Color(0x0D141824),
    border: Color(0x1C141824),
    accentPurple: Color(0xFF6B57F6),
    accentTeal: Color(0xFF0F9F85),
    textPrimary: Color(0xFF171B27),
    textSecondary: Color(0xB8171B27),
    textTertiary: Color(0x80171B27),
    overlayBackdrop: Color(0x9EEFF3FF),
    sheetGradStart: Color(0xFAFFFFFF),
    sheetGradEnd: Color(0xEDF3F6FF),
    logsSheetStart: Color(0xF8FFFFFF),
    logsSheetEnd: Color(0xEBF1F5FF),
    settSheetStart: Color(0xF8FFFFFF),
    settSheetEnd: Color(0xEDF6F3FF),
    adminSheetStart: Color(0xF8FFFFFF),
    adminSheetEnd: Color(0xEDF5F6FF),
    dnsSheetStart: Color(0xFAFFFFFF),
    dnsSheetEnd: Color(0xF5EFF7F5),
    appsSheetStart: Color(0xFAFFFFFF),
    appsSheetEnd: Color(0xF5F3F4FF),
    routesSheetStart: Color(0xFAFFFFFF),
    routesSheetEnd: Color(0xF5F4F5FF),
    addServerSheetStart: Color(0xFCFFFFFF),
    addServerSheetEnd: Color(0xF5F2F4FF),
    miniToastBg: Color(0xF5FFFFFF),
    shadowColor: Color(0x33759EAD),
    greenConnected: Color(0xFF0F9F85),
    redError: Color(0xFFE53935),
    yellowWarning: Color(0xFFF9A825),
    blueDebug: Color(0xFF3B82F6),
    connectingBlue: Color(0xFF3B82F6),
    dangerRose: Color(0xFFE11D48),
    pingGood: Color(0xFF059669),
    pingMid: Color(0xFFD97706),
    pingHigh: Color(0xFFE11D48),
    statDl: Color(0xFF0891B2),
    statUl: Color(0xFF7C3AED),
    statSe: Color(0xFFEA580C),
    statPk: Color(0xFF0F9F85),
    adminHeroGradStart: Color(0x2E6B57F6),
    adminHeroGradMid: Color(0xFAFFFFFF),
    adminHeroGradEnd: Color(0xFAEDF2FF),
  );
}

class GhostColorsProvider extends InheritedWidget {
  final GhostColors colors;

  const GhostColorsProvider({
    super.key,
    required this.colors,
    required super.child,
  });

  static GhostColors of(BuildContext context) {
    final provider =
        context.dependOnInheritedWidgetOfExactType<GhostColorsProvider>();
    return provider?.colors ?? GhostColors.darkColors;
  }

  @override
  bool updateShouldNotify(GhostColorsProvider oldWidget) =>
      !identical(colors, oldWidget.colors);
}

extension GhostColorsX on BuildContext {
  GhostColors get ghostColors => GhostColorsProvider.of(this);
}
