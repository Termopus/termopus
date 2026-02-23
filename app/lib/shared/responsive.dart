import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Responsive system adapted for Termopus (mobile + tablet).
///
/// Provides device-aware breakpoints, responsive typography, padding,
/// icon sizing, platform-adaptive widgets, and BuildContext extensions.

// ---------------------------------------------------------------------------
// Device types
// ---------------------------------------------------------------------------

enum DeviceType {
  mobile, // < 480px
  largeMobile, // 480px - 800px
  tablet, // 800px - 1000px
  desktop, // 1000px - 1440px
  largeDesktop, // > 1440px
}

enum ScreenOrientation { portrait, landscape }

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

class ResponsiveConstants {
  ResponsiveConstants._();

  // Breakpoints
  static const double mobileBreakpoint = 480.0;
  static const double tabletBreakpoint = 800.0;
  static const double desktopBreakpoint = 1000.0;
  static const double largeDesktopBreakpoint = 1440.0;

  // Touch targets (Material Design minimum)
  static const double minTouchTarget = 48.0;

  // Container width factors
  static const double mobileWidthFactor = 0.95;
  static const double largeMobileWidthFactor = 0.9;
  static const double tabletWidthFactor = 0.85;
  static const double desktopWidthFactor = 0.8;
  static const double largeDesktopWidthFactor = 0.75;
}

// ---------------------------------------------------------------------------
// Responsive typography (device + system accessibility scaling)
// ---------------------------------------------------------------------------

class ResponsiveTypography {
  static const Map<String, Map<DeviceType, double>> _tokens = {
    'headline': {
      DeviceType.mobile: 24.0,
      DeviceType.largeMobile: 26.0,
      DeviceType.tablet: 28.0,
      DeviceType.desktop: 32.0,
      DeviceType.largeDesktop: 36.0,
    },
    'title': {
      DeviceType.mobile: 20.0,
      DeviceType.largeMobile: 22.0,
      DeviceType.tablet: 24.0,
      DeviceType.desktop: 26.0,
      DeviceType.largeDesktop: 28.0,
    },
    'body': {
      DeviceType.mobile: 14.0,
      DeviceType.largeMobile: 15.0,
      DeviceType.tablet: 16.0,
      DeviceType.desktop: 17.0,
      DeviceType.largeDesktop: 18.0,
    },
    'caption': {
      DeviceType.mobile: 12.0,
      DeviceType.largeMobile: 13.0,
      DeviceType.tablet: 14.0,
      DeviceType.desktop: 14.0,
      DeviceType.largeDesktop: 16.0,
    },
    'button': {
      DeviceType.mobile: 14.0,
      DeviceType.largeMobile: 15.0,
      DeviceType.tablet: 16.0,
      DeviceType.desktop: 16.0,
      DeviceType.largeDesktop: 18.0,
    },
    'code': {
      DeviceType.mobile: 12.0,
      DeviceType.largeMobile: 13.0,
      DeviceType.tablet: 14.0,
      DeviceType.desktop: 14.0,
      DeviceType.largeDesktop: 15.0,
    },
  };

  /// Get font size scaled for device type and system accessibility settings.
  /// Combined scaling is capped at 2.0x (WCAG compliant).
  static double getFontSize(BuildContext context, String token) {
    final deviceType = Responsive.getDeviceType(context);
    final baseSize = _tokens[token]?[deviceType] ?? 14.0;
    final systemScale = MediaQuery.of(context).textScaler.scale(1.0);
    return baseSize * systemScale.clamp(0.8, 2.0);
  }

  /// Raw font size without system accessibility scaling.
  static double getRawFontSize(BuildContext context, String token) {
    final deviceType = Responsive.getDeviceType(context);
    return _tokens[token]?[deviceType] ?? 14.0;
  }
}

// ---------------------------------------------------------------------------
// Main responsive system
// ---------------------------------------------------------------------------

class Responsive {
  Responsive._();

  // Platform detection
  static bool get isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  static bool get isIOS =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  static bool get isMobile => isAndroid || isIOS;

  // ---- Device type detection ----

  static DeviceType getDeviceType(BuildContext context) {
    final mq = MediaQuery.maybeOf(context);
    if (mq == null) return DeviceType.mobile;

    final size = mq.size;
    final aspectRatio = size.aspectRatio;

    // Foldables / ultra-wide: fall back to shortest side
    if (aspectRatio > 2.5 || aspectRatio < 0.4) {
      return _byShortestSide(size.shortestSide);
    }
    return _byWidth(size.width);
  }

  static DeviceType _byShortestSide(double s) {
    if (s < 360) return DeviceType.mobile;
    if (s < 600) return DeviceType.largeMobile;
    if (s < 840) return DeviceType.tablet;
    if (s < 1200) return DeviceType.desktop;
    return DeviceType.largeDesktop;
  }

  static DeviceType _byWidth(double w) {
    if (w < ResponsiveConstants.mobileBreakpoint) return DeviceType.mobile;
    if (w < ResponsiveConstants.tabletBreakpoint) return DeviceType.largeMobile;
    if (w < ResponsiveConstants.desktopBreakpoint) return DeviceType.tablet;
    if (w < ResponsiveConstants.largeDesktopBreakpoint) {
      return DeviceType.desktop;
    }
    return DeviceType.largeDesktop;
  }

  // ---- Orientation ----

  static ScreenOrientation getOrientation(BuildContext context) {
    final mq = MediaQuery.maybeOf(context);
    if (mq == null) return ScreenOrientation.portrait;
    return mq.orientation == Orientation.portrait
        ? ScreenOrientation.portrait
        : ScreenOrientation.landscape;
  }

  static bool isPortrait(BuildContext context) =>
      getOrientation(context) == ScreenOrientation.portrait;

  static bool isLandscape(BuildContext context) => !isPortrait(context);

  // ---- Device category checks ----

  static bool isMobileDevice(BuildContext context) {
    final dt = getDeviceType(context);
    return dt == DeviceType.mobile || dt == DeviceType.largeMobile;
  }

  static bool isTabletDevice(BuildContext context) =>
      getDeviceType(context) == DeviceType.tablet;

  static bool isDesktopDevice(BuildContext context) {
    final dt = getDeviceType(context);
    return dt == DeviceType.desktop || dt == DeviceType.largeDesktop;
  }

  // ---- Responsive value picker ----

  static T value<T>(
    BuildContext context, {
    required T mobile,
    T? largeMobile,
    T? tablet,
    T? desktop,
    T? largeDesktop,
  }) {
    switch (getDeviceType(context)) {
      case DeviceType.mobile:
        return mobile;
      case DeviceType.largeMobile:
        return largeMobile ?? mobile;
      case DeviceType.tablet:
        return tablet ?? largeMobile ?? mobile;
      case DeviceType.desktop:
        return desktop ?? tablet ?? largeMobile ?? mobile;
      case DeviceType.largeDesktop:
        return largeDesktop ?? desktop ?? tablet ?? largeMobile ?? mobile;
    }
  }

  // ---- Responsive padding ----

  static EdgeInsets padding(BuildContext context) {
    return value(
      context,
      mobile: const EdgeInsets.all(8.0),
      largeMobile: const EdgeInsets.all(12.0),
      tablet: const EdgeInsets.all(16.0),
      desktop: const EdgeInsets.all(20.0),
      largeDesktop: const EdgeInsets.all(24.0),
    );
  }

  /// Horizontal padding for screen content.
  static double horizontalPadding(BuildContext context) {
    return value<double>(
      context,
      mobile: 12.0,
      largeMobile: 16.0,
      tablet: 24.0,
      desktop: 32.0,
    );
  }

  // ---- Responsive font size (ad-hoc, non-token) ----

  static double fontSize(
    BuildContext context, {
    required double mobile,
    double? largeMobile,
    double? tablet,
    double? desktop,
  }) {
    return value(
      context,
      mobile: mobile,
      largeMobile: largeMobile,
      tablet: tablet,
      desktop: desktop,
    );
  }

  // ---- Responsive icon size ----

  static double iconSize(BuildContext context) {
    return value<double>(
      context,
      mobile: 20.0,
      largeMobile: 22.0,
      tablet: 24.0,
      desktop: 26.0,
    );
  }

  // ---- Responsive spacing ----

  static double spacing(BuildContext context) {
    return value<double>(
      context,
      mobile: 8.0,
      largeMobile: 10.0,
      tablet: 12.0,
      desktop: 16.0,
    );
  }

  // ---- Screen utilities ----

  static Size screenSize(BuildContext context) =>
      MediaQuery.maybeOf(context)?.size ?? Size.zero;

  static double screenWidth(BuildContext context) =>
      MediaQuery.maybeOf(context)?.size.width ?? 0.0;

  static double screenHeight(BuildContext context) =>
      MediaQuery.maybeOf(context)?.size.height ?? 0.0;

  static EdgeInsets safeArea(BuildContext context) =>
      MediaQuery.maybeOf(context)?.padding ?? EdgeInsets.zero;

  // ---- Container width ----

  static double containerWidth(BuildContext context) {
    final sw = screenWidth(context);
    if (sw <= 0) return 300.0;
    return value<double>(
      context,
      mobile: sw * ResponsiveConstants.mobileWidthFactor,
      largeMobile: sw * ResponsiveConstants.largeMobileWidthFactor,
      tablet: sw * ResponsiveConstants.tabletWidthFactor,
      desktop: sw * ResponsiveConstants.desktopWidthFactor,
      largeDesktop: sw * ResponsiveConstants.largeDesktopWidthFactor,
    );
  }

  // ---- Chat bubble max width ----

  static double chatBubbleMaxWidth(BuildContext context) {
    final sw = screenWidth(context);
    return value<double>(
      context,
      mobile: sw * 0.82,
      largeMobile: sw * 0.78,
      tablet: sw * 0.70,
      desktop: sw * 0.60,
    );
  }

  // ---- Platform-adaptive widgets ----

  /// Returns the appropriate widget based on the current platform.
  /// Uses Cupertino on iOS, Material on Android/other.
  static Widget platformWidget({
    required Widget material,
    required Widget cupertino,
  }) {
    if (isIOS) return cupertino;
    return material;
  }

  /// Platform-adaptive loading indicator.
  static Widget loadingIndicator({Color? color}) {
    if (isIOS) return CupertinoActivityIndicator(color: color);
    return CircularProgressIndicator(color: color);
  }

  /// Platform-adaptive app bar height (accounts for tablet).
  static double appBarHeight(BuildContext context) {
    return value<double>(
      context,
      mobile: kToolbarHeight,
      tablet: kToolbarHeight + 8,
      desktop: kToolbarHeight + 12,
    );
  }

  /// Responsive grid columns (useful for tablet layouts).
  static int gridColumns(BuildContext context) {
    return value<int>(
      context,
      mobile: 1,
      largeMobile: 1,
      tablet: 2,
      desktop: 3,
      largeDesktop: 4,
    );
  }

  // ---- Accessibility ----

  static double textScaleFactor(BuildContext context) =>
      MediaQuery.of(context).textScaler.scale(1.0);

  static bool isUsingLargeFonts(BuildContext context) =>
      textScaleFactor(context) > 1.3;

  static bool isReducedMotion(BuildContext context) =>
      MediaQuery.of(context).disableAnimations;
}

// ---------------------------------------------------------------------------
// BuildContext extensions — clean call sites
// ---------------------------------------------------------------------------

extension ResponsiveExtension on BuildContext {
  // Device
  DeviceType get deviceType => Responsive.getDeviceType(this);
  bool get isMobileDevice => Responsive.isMobileDevice(this);
  bool get isTabletDevice => Responsive.isTabletDevice(this);
  bool get isDesktopDevice => Responsive.isDesktopDevice(this);
  bool get isPortrait => Responsive.isPortrait(this);
  bool get isLandscape => Responsive.isLandscape(this);

  // Screen
  double get screenWidth => Responsive.screenWidth(this);
  double get screenHeight => Responsive.screenHeight(this);
  EdgeInsets get safeArea => Responsive.safeArea(this);

  // Sizing
  EdgeInsets get rPadding => Responsive.padding(this);
  double get rHorizontalPadding => Responsive.horizontalPadding(this);
  double get rIconSize => Responsive.iconSize(this);
  double get rSpacing => Responsive.spacing(this);
  double get rContainerWidth => Responsive.containerWidth(this);
  double get rChatBubbleMaxWidth => Responsive.chatBubbleMaxWidth(this);

  // Typography (semantic tokens)
  double get headlineFontSize => ResponsiveTypography.getFontSize(this, 'headline');
  double get titleFontSize => ResponsiveTypography.getFontSize(this, 'title');
  double get bodyFontSize => ResponsiveTypography.getFontSize(this, 'body');
  double get captionFontSize => ResponsiveTypography.getFontSize(this, 'caption');
  double get buttonFontSize => ResponsiveTypography.getFontSize(this, 'button');
  double get codeFontSize => ResponsiveTypography.getFontSize(this, 'code');

  // Ad-hoc responsive value
  T rValue<T>({
    required T mobile,
    T? largeMobile,
    T? tablet,
    T? desktop,
    T? largeDesktop,
  }) =>
      Responsive.value(
        this,
        mobile: mobile,
        largeMobile: largeMobile,
        tablet: tablet,
        desktop: desktop,
        largeDesktop: largeDesktop,
      );

  // Ad-hoc responsive font size
  double rFontSize({
    required double mobile,
    double? largeMobile,
    double? tablet,
    double? desktop,
  }) =>
      Responsive.fontSize(
        this,
        mobile: mobile,
        largeMobile: largeMobile,
        tablet: tablet,
        desktop: desktop,
      );

  // Platform
  bool get isIOSPlatform => Responsive.isIOS;
  bool get isAndroidPlatform => Responsive.isAndroid;

  // Grid
  int get rGridColumns => Responsive.gridColumns(this);
}
