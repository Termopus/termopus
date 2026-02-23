import 'package:flutter/material.dart';

/// Application theme - Termopus brand aesthetic.
///
/// Colors based on Termopus logo: Deep navy background,
/// cyan/blue octopus, purple/violet accents.
class AppTheme {
  AppTheme._();

  // ---------------------------------------------------------------------------
  // Color palette - Termopus Brand
  // ---------------------------------------------------------------------------

  // Backgrounds (from logo dark navy)
  static const Color background = Color(0xFF0D0D1A);
  static const Color surface = Color(0xFF1A1B2E);
  static const Color surfaceLight = Color(0xFF252640);
  static const Color surfaceElevated = Color(0xFF2D2E4A);

  // Brand colors (from logo octopus)
  static const Color primary = Color(0xFF7DD3FC);       // Light cyan/sky blue
  static const Color primaryLight = Color(0xFFA5E4FC);
  static const Color accent = Color(0xFF9D8CFF);        // Purple/violet
  static const Color accentLight = Color(0xFFB8ABFF);

  // Secondary brand colors
  static const Color brandCyan = Color(0xFF67E8F9);     // Bright cyan
  static const Color brandPurple = Color(0xFF8B7CF6);   // Purple
  static const Color brandViolet = Color(0xFFA78BFA);   // Light violet

  // Semantic colors
  static const Color success = Color(0xFF4ADE80);       // Green for Allow
  static const Color error = Color(0xFFF87171);         // Red for errors
  static const Color warning = Color(0xFFFBBF24);       // Yellow

  // Text colors
  static const Color textPrimary = Color(0xFFF8FAFC);
  static const Color textSecondary = Color(0xFFB8C0D0);
  static const Color textMuted = Color(0xFF6B7280);
  static const Color divider = Color(0xFF374151);

  // Chat bubbles
  static const Color claudeBubble = Color(0xFF1E1F35);
  static const Color userBubble = Color(0xFF3B82F6);    // Blue for user
  static const Color systemBubble = Color(0xFF252640);

  // Status colors
  static const Color statusOnline = Color(0xFF4ADE80);
  static const Color statusWorking = Color(0xFF7DD3FC);
  static const Color statusOffline = Color(0xFF6B7280);

  // Diff-specific
  static const Color diffAdd = Color(0xFF166534);
  static const Color diffRemove = Color(0xFF991B1B);
  static const Color diffContext = Color(0xFF1E1F35);

  // Terminal mode
  static const Color terminalBg = Color(0xFF000000);
  static const Color terminalPrompt = Color(0xFF4ADE80);
  static const Color terminalText = Color(0xFFE4E4E7);
  static const Color terminalDim = Color(0xFF52525B);
  static const Color terminalSurface = Color(0xFF0A0A0A);

  // ---------------------------------------------------------------------------
  // Gradients (matching logo gradient feel)
  // ---------------------------------------------------------------------------

  static const LinearGradient primaryGradient = LinearGradient(
    colors: [Color(0xFF7DD3FC), Color(0xFF67E8F9)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient accentGradient = LinearGradient(
    colors: [Color(0xFF8B7CF6), Color(0xFFA78BFA)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient brandGradient = LinearGradient(
    colors: [Color(0xFF67E8F9), Color(0xFF8B7CF6)],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  static const LinearGradient surfaceGradient = LinearGradient(
    colors: [Color(0xFF1A1B2E), Color(0xFF0D0D1A)],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  // ---------------------------------------------------------------------------
  // Shadows
  // ---------------------------------------------------------------------------

  static List<BoxShadow> get softShadow => [
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.4),
      blurRadius: 20,
      offset: const Offset(0, 8),
    ),
  ];

  static List<BoxShadow> get glowShadow => [
    BoxShadow(
      color: primary.withValues(alpha: 0.3),
      blurRadius: 20,
      offset: const Offset(0, 4),
    ),
  ];

  static List<BoxShadow> get accentGlow => [
    BoxShadow(
      color: accent.withValues(alpha: 0.3),
      blurRadius: 16,
      offset: const Offset(0, 4),
    ),
  ];

  // ---------------------------------------------------------------------------
  // Border Radius
  // ---------------------------------------------------------------------------

  static const double radiusSmall = 8.0;
  static const double radiusMedium = 12.0;
  static const double radiusLarge = 16.0;
  static const double radiusXLarge = 24.0;
  static const double radiusRound = 100.0;

  // ---------------------------------------------------------------------------
  // ThemeData
  // ---------------------------------------------------------------------------

  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: background,
      colorScheme: const ColorScheme.dark(
        primary: primary,
        secondary: accent,
        surface: surface,
        error: error,
        onPrimary: Color(0xFF0D0D1A),
        onSecondary: Colors.white,
        onSurface: textPrimary,
        onError: Colors.white,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: textPrimary,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.3,
        ),
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusLarge),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: const Color(0xFF0D0D1A),
          elevation: 0,
          shadowColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusMedium),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: textPrimary,
          side: BorderSide(color: divider.withValues(alpha: 0.5)),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusMedium),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: primary,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceLight,
        hintStyle: const TextStyle(color: textMuted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusRound),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 20,
          vertical: 16,
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: divider,
        thickness: 0.5,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: primary,
        foregroundColor: const Color(0xFF0D0D1A),
        elevation: 4,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusLarge),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        textColor: textPrimary,
        iconColor: textSecondary,
        contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return primary;
          return textMuted;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return primary.withValues(alpha: 0.4);
          }
          return surfaceLight;
        }),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: surfaceElevated,
        contentTextStyle: const TextStyle(color: textPrimary),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMedium),
        ),
        behavior: SnackBarBehavior.floating,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        dragHandleColor: textMuted.withValues(alpha: 0.3),
        dragHandleSize: const Size(40, 4),
      ),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(
          color: textPrimary,
          fontSize: 32,
          fontWeight: FontWeight.bold,
          letterSpacing: -0.5,
        ),
        headlineMedium: TextStyle(
          color: textPrimary,
          fontSize: 24,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.3,
        ),
        titleLarge: TextStyle(
          color: textPrimary,
          fontSize: 20,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
        titleMedium: TextStyle(
          color: textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.w500,
        ),
        bodyLarge: TextStyle(
          color: textPrimary,
          fontSize: 16,
          height: 1.5,
        ),
        bodyMedium: TextStyle(
          color: textSecondary,
          fontSize: 14,
          height: 1.5,
        ),
        bodySmall: TextStyle(
          color: textMuted,
          fontSize: 12,
          height: 1.4,
        ),
        labelLarge: TextStyle(
          color: textPrimary,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
