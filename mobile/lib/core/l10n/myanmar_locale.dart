import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// Minimal key-based localization loader for the `assets/l10n/*.json` files.
///
/// Spec reference: "Localization Files (i18n) — my.json on backend & frontend".
/// Call [loadLocale] once during app bootstrap (or lazy on first [t] lookup);
/// translations are cached as an in-memory `Map<String, String>`.
class MyanmarLocale {
  MyanmarLocale._();

  static const String defaultLocale = 'my';
  static Map<String, String> _strings = const {};
  static String _currentLocale = defaultLocale;

  static String get currentLocale => _currentLocale;

  static bool get isLoaded => _strings.isNotEmpty;

  /// Loads the JSON locale file for [locale] ("my" or "en") into the cache.
  static Future<void> loadLocale({
    String locale = defaultLocale,
    String basePath = 'assets/l10n',
  }) async {
    final data = await rootBundle.loadString('$basePath/$locale.json');
    final decoded = jsonDecode(data);
    if (decoded is! Map<String, dynamic>) {
      throw FormatException('Invalid locale map in $locale.json');
    }
    _strings = decoded.map((key, value) => MapEntry(key, value.toString()));
    _currentLocale = locale;
  }

  /// Returns the translated string for [key] (the key itself as fallback).
  static String t(String key, {String? fallback}) =>
      _strings[key] ?? fallback ?? key;
}