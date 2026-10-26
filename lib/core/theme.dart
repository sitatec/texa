import 'package:flutter/material.dart';

const texaRed = Color(0xFFEF6666);
const texaBlue = Color(0xFF3B82F6);
const texaGreen = Color(0xFF10B981);
const texaYellow = Color(0xFFFBBF24);

final _primaryColor = texaBlue;

final _defaultButtonStyle = ButtonStyle(
  visualDensity: .standard,
  shape: WidgetStatePropertyAll(
    RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
  ),
);
final _filledButtonStyle = _defaultButtonStyle.copyWith(
  elevation: WidgetStateProperty.resolveWith((states) {
    if (states.contains(WidgetState.disabled)) return 0;
    if (states.contains(WidgetState.hovered)) return 2;
    return 1.5;
  }),
);
final _iconButtonStyle = _defaultButtonStyle.copyWith(
  visualDensity: .standard,
  shape: WidgetStatePropertyAll(
    RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
  ),
);

ThemeData get lightTheme {
  final baseLightTheme = ThemeData.light(useMaterial3: true).copyWith(
    primaryColor: _primaryColor,
    colorScheme: ColorScheme.fromSeed(
      seedColor: _primaryColor,
      primary: _primaryColor,
      brightness: Brightness.light,
      surface: const Color.fromARGB(255, 255, 254, 253),
      surfaceContainer: Colors.grey.shade50,
      surfaceContainerLow: Colors.white,
      surfaceContainerHigh: Colors.grey.shade200,
    ),
  );
  final lightTextTheme = baseLightTheme.textTheme.apply(
    fontFamily: 'GoogleSansFlex',
  );

  return ThemeData(
    fontFamily: 'GoogleSansFlex',
    textTheme: lightTextTheme,
    tabBarTheme: baseLightTheme.tabBarTheme.copyWith(
      dividerColor: baseLightTheme.colorScheme.onSurface.withValues(alpha: 0.3),
      labelColor: baseLightTheme.colorScheme.onSurface,
      unselectedLabelColor: baseLightTheme.colorScheme.onSurface.withValues(
        alpha: 0.7,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(style: _defaultButtonStyle),
    filledButtonTheme: FilledButtonThemeData(style: _filledButtonStyle),
    textButtonTheme: TextButtonThemeData(style: _defaultButtonStyle),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: _defaultButtonStyle.copyWith(
        side: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? BorderSide(color: baseLightTheme.disabledColor)
              : BorderSide(color: _primaryColor),
        ),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(style: _iconButtonStyle),
    cardTheme: baseLightTheme.cardTheme.copyWith(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(width: 0.2, color: texaBlue),
      ),
    ),
    scaffoldBackgroundColor: baseLightTheme.colorScheme.surface,
    useMaterial3: true,
    primaryColor: _primaryColor,
    colorScheme: baseLightTheme.colorScheme.copyWith(surface: Colors.white),
    dividerColor: baseLightTheme.colorScheme.onSurface.withValues(alpha: 0.3),
    checkboxTheme: baseLightTheme.checkboxTheme.copyWith(
      side: BorderSide(width: 1.5, color: baseLightTheme.colorScheme.onSurface),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(3),
        side: BorderSide(
          width: 0.2,
          color: _primaryColor.withValues(alpha: 0.5),
        ),
      ),
    ),
  );
}

ThemeData get darkTheme {
  var baseDarkTheme = ThemeData.dark(useMaterial3: true).copyWith(
    primaryColor: _primaryColor,
    colorScheme: ColorScheme.fromSeed(
      seedColor: _primaryColor,
      primary: _primaryColor,
      surface: const Color(0xFF131314),
      brightness: Brightness.dark,
      surfaceContainerLow: const Color(0xFF1c1c1e),
      surfaceContainer: const Color(0xFF1e1e1f),
      surfaceContainerHigh: const Color(0xFF2d2d30),
    ),
  );
  baseDarkTheme = baseDarkTheme.copyWith(
    colorScheme: baseDarkTheme.colorScheme.copyWith(
      onSurface: baseDarkTheme.colorScheme.onSurface.withValues(alpha: 0.87),
    ),
  );
  final darkTextTheme = baseDarkTheme.textTheme.apply(
    fontFamily: 'GoogleSansFlex',
    bodyColor: baseDarkTheme.colorScheme.onSurface,
    displayColor: baseDarkTheme.colorScheme.onSurface,
    decorationColor: baseDarkTheme.colorScheme.onSurface,
  );

  return ThemeData(
    fontFamily: 'GoogleSansFlex',
    textTheme: darkTextTheme,
    tabBarTheme: baseDarkTheme.tabBarTheme.copyWith(
      labelColor: baseDarkTheme.colorScheme.onSurface,
      unselectedLabelColor: baseDarkTheme.colorScheme.onSurface.withValues(
        alpha: 0.7,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(style: _defaultButtonStyle),
    filledButtonTheme: FilledButtonThemeData(style: _filledButtonStyle),
    textButtonTheme: TextButtonThemeData(style: _defaultButtonStyle),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: _defaultButtonStyle.copyWith(
        side: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? BorderSide(color: baseDarkTheme.disabledColor)
              : BorderSide(color: _primaryColor),
        ),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(style: _iconButtonStyle),
    cardTheme: baseDarkTheme.cardTheme.copyWith(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    useMaterial3: true,
    primaryColor: _primaryColor,
    colorScheme: baseDarkTheme.colorScheme.copyWith(
      onPrimary: Colors.white.withValues(alpha: 0.94),
    ),
    checkboxTheme: baseDarkTheme.checkboxTheme.copyWith(
      side: BorderSide(width: 1.5, color: baseDarkTheme.colorScheme.onSurface),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
    ),
  );
}
