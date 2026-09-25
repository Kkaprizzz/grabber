import 'package:flutter/material.dart';

/// Tokens from DESIGN.md («Персик и песок»). Every colour in the app comes from here.
class Palette {
  const Palette({
    required this.brightness,
    required this.bg,
    required this.surface,
    required this.surfaceMuted,
    required this.outline,
    required this.text,
    required this.textMuted,
    required this.accent,
    required this.onAccent,
    required this.accentInk,
    required this.sand,
    required this.okFill,
    required this.okInk,
    required this.warnFill,
    required this.warnInk,
    required this.errFill,
    required this.errInk,
  });

  final Brightness brightness;
  final Color bg, surface, surfaceMuted, outline, text, textMuted;
  final Color accent, onAccent, accentInk, sand;
  final Color okFill, okInk, warnFill, warnInk, errFill, errInk;

  static const light = Palette(
    brightness: Brightness.light,
    bg: Color(0xFFF8F4EF),
    surface: Color(0xFFFFFFFF),
    surfaceMuted: Color(0xFFF1EBE3),
    outline: Color(0xFFE3DACE),
    text: Color(0xFF2E2823),
    textMuted: Color(0xFF756B61),
    accent: Color(0xFFF4B993),
    onAccent: Color(0xFF2E2823),
    accentInk: Color(0xFF9A5433),
    sand: Color(0xFFE8D9BF),
    okFill: Color(0xFFB9D8B4),
    okInk: Color(0xFF2F6B45),
    warnFill: Color(0xFFEBDDA0),
    warnInk: Color(0xFF6E5A12),
    errFill: Color(0xFFF2C3CB),
    errInk: Color(0xFF9B2F46),
  );

  static const dark = Palette(
    brightness: Brightness.dark,
    bg: Color(0xFF1F1C1A),
    surface: Color(0xFF282421),
    surfaceMuted: Color(0xFF322D29),
    outline: Color(0xFF433C36),
    text: Color(0xFFF1ECE6),
    textMuted: Color(0xFFB0A69C),
    accent: Color(0xFFF0BFA3),
    onAccent: Color(0xFF1F1C1A),
    accentInk: Color(0xFFF0BFA3),
    sand: Color(0xFF4A4033),
    okFill: Color(0xFF27382A),
    okInk: Color(0xFFB9D8B4),
    warnFill: Color(0xFF3A3522),
    warnInk: Color(0xFFEBDDA0),
    errFill: Color(0xFF3D2429),
    errInk: Color(0xFFF2C3CB),
  );

  static Palette of(BuildContext context) => Theme.of(context).extension<PaletteExt>()!.palette;
}

class PaletteExt extends ThemeExtension<PaletteExt> {
  const PaletteExt(this.palette);
  final Palette palette;

  @override
  PaletteExt copyWith() => this;

  @override
  PaletteExt lerp(covariant PaletteExt? other, double t) => t < 0.5 || other == null ? this : other;
}

/// One curve for the whole app (DESIGN.md → Моушен).
const kEase = Cubic(0.22, 1, 0.36, 1);
const kFast = Duration(milliseconds: 180);
const kPage = Duration(milliseconds: 240);

/// Respects the system "remove animations" setting.
Duration motion(BuildContext context, Duration d) =>
    MediaQuery.of(context).disableAnimations ? Duration.zero : d;

const _mono = 'IBMPlexMono';
const _sans = 'IBMPlexSans';

/// Monospace with tabular figures, for sizes, durations and percentages.
TextStyle mono(BuildContext context, {double size = 14, FontWeight weight = FontWeight.w400, Color? color}) =>
    TextStyle(
      fontFamily: _mono,
      fontSize: size,
      height: size >= 20 ? 1.1 : 1.4,
      fontWeight: weight,
      color: color ?? Palette.of(context).text,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

ThemeData buildTheme(Palette p) {
  final scheme = ColorScheme(
    brightness: p.brightness,
    primary: p.accent,
    onPrimary: p.onAccent,
    primaryContainer: p.accent,
    onPrimaryContainer: p.onAccent,
    secondary: p.sand,
    onSecondary: p.text,
    secondaryContainer: p.surfaceMuted,
    onSecondaryContainer: p.text,
    tertiary: p.accentInk,
    onTertiary: p.surface,
    error: p.errInk,
    onError: p.surface,
    errorContainer: p.errFill,
    onErrorContainer: p.errInk,
    surface: p.surface,
    onSurface: p.text,
    onSurfaceVariant: p.textMuted,
    surfaceContainerLowest: p.surface,
    surfaceContainerLow: p.surface,
    surfaceContainer: p.surface,
    surfaceContainerHigh: p.surfaceMuted,
    surfaceContainerHighest: p.surfaceMuted,
    outline: p.outline,
    outlineVariant: p.outline,
    inverseSurface: p.text,
    onInverseSurface: p.bg,
    inversePrimary: p.accentInk,
    shadow: Colors.transparent,
    scrim: Colors.black54,
  );

  TextStyle t(double size, double height, FontWeight w, [Color? c]) =>
      TextStyle(fontFamily: _sans, fontSize: size, height: height / size, fontWeight: w, color: c ?? p.text);

  final text = TextTheme(
    headlineSmall: t(24, 30, FontWeight.w600),
    titleLarge: t(20, 26, FontWeight.w600),
    titleMedium: t(16, 22, FontWeight.w500),
    titleSmall: t(14, 20, FontWeight.w500),
    bodyLarge: t(16, 22, FontWeight.w400),
    bodyMedium: t(15, 21, FontWeight.w400),
    bodySmall: t(12, 16, FontWeight.w400, p.textMuted),
    labelLarge: t(14, 20, FontWeight.w500),
    labelMedium: t(13, 18, FontWeight.w500),
    labelSmall: t(12, 16, FontWeight.w500, p.textMuted),
  );

  const r10 = BorderRadius.all(Radius.circular(10));
  const r12 = BorderRadius.all(Radius.circular(12));

  return ThemeData(
    useMaterial3: true,
    brightness: p.brightness,
    colorScheme: scheme,
    fontFamily: _sans,
    textTheme: text,
    scaffoldBackgroundColor: p.bg,
    extensions: [PaletteExt(p)],
    // InkSparkle runs a fragment shader per tap; on the Galaxy S8's Mali GPU
    // under Skia/GL that stutters. InkRipple is plain drawing.
    splashFactory: InkRipple.splashFactory,
    appBarTheme: AppBarTheme(
      backgroundColor: p.bg,
      foregroundColor: p.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: text.titleLarge,
    ),
    cardTheme: CardThemeData(
      color: p.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: r12, side: BorderSide(color: p.outline)),
    ),
    dividerTheme: DividerThemeData(color: p.outline, thickness: 1, space: 1),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.surfaceMuted,
      border: const OutlineInputBorder(borderRadius: r10, borderSide: BorderSide.none),
      enabledBorder: const OutlineInputBorder(borderRadius: r10, borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(borderRadius: r10, borderSide: BorderSide(color: p.accentInk, width: 1.5)),
      errorBorder: OutlineInputBorder(borderRadius: r10, borderSide: BorderSide(color: p.errInk)),
      labelStyle: TextStyle(color: p.textMuted),
      hintStyle: TextStyle(color: p.textMuted),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.accent,
        foregroundColor: p.onAccent,
        disabledBackgroundColor: p.surfaceMuted,
        shape: const RoundedRectangleBorder(borderRadius: r10),
        minimumSize: const Size(64, 48),
        textStyle: text.labelLarge,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.text,
        side: BorderSide(color: p.outline),
        shape: const RoundedRectangleBorder(borderRadius: r10),
        minimumSize: const Size(64, 48),
        textStyle: text.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: p.accentInk, textStyle: text.labelLarge),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: p.surfaceMuted,
      selectedColor: p.accent,
      side: BorderSide.none,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(8))),
      labelStyle: text.labelMedium,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        selectedBackgroundColor: p.accent,
        selectedForegroundColor: p.onAccent,
        side: BorderSide(color: p.outline),
        shape: const RoundedRectangleBorder(borderRadius: r10),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.accentInk : p.textMuted),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.accent : p.surfaceMuted),
      trackOutlineColor: WidgetStateProperty.all(p.outline),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: p.textMuted,
      titleTextStyle: text.bodyMedium,
      subtitleTextStyle: text.bodySmall,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: p.text,
      contentTextStyle: t(14, 20, FontWeight.w400, p.bg),
      shape: const RoundedRectangleBorder(borderRadius: r10),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
      titleTextStyle: text.titleMedium,
      contentTextStyle: text.bodyMedium,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.surface,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: p.accentInk,
      linearTrackColor: p.sand,
      linearMinHeight: 4,
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.accentInk : Colors.transparent),
      checkColor: WidgetStateProperty.all(p.surface),
      side: BorderSide(color: p.textMuted, width: 1.5),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(4))),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.accentInk : p.textMuted),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.surface,
      shape: RoundedRectangleBorder(borderRadius: r10, side: BorderSide(color: p.outline)),
      elevation: 0,
    ),
  );
}
