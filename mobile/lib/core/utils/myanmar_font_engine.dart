import 'package:flutter/material.dart';

/// Burmese (Zawgyi vs Unicode) text detection & automatic font-style resolver.
///
/// Spec reference: Dynamic Font Loader Utility — Zawgyi/Unicode Auto-Detection.
///
/// Usage:
///   MyanmarFontEngine.getCorrectStyle('မိုးကုတ်', baseStyle: base)
///   MyanmarFontEngine.renderText('မိုးကုတ်')
class MyanmarFontEngine {
  MyanmarFontEngine._();

  // Regex detects Zawgyi-specific combining clusters that do not appear in
  // valid Unicode Myanmar:
  //   1. a bare killed syllable ("က်") written with a trailing asat (U+103A)
  //      that is NOT part of a medial cluster (lookbehind keeps legitimate
  //      Unicode words like "မြန်မာ" / "ကန်" out of this branch);
  //   2. U+1031 placed AFTER the base consonant (Unicode always puts "ေ"
  //      first), e.g. Zawgyi "ကော";
  //   3. vowel sign BEFORE the asat (Zawgyi "ကာ်"), matching the "(consonant
  //      [+ medial/vowel] + resulting asat)" Zawgyi order;
  //   4. asat followed by a vowel/tone dot — a trailing mark Zawgyi appends
  //      at the end of the syllable instead of inserting before the vowel.
  static final RegExp _zgPattern = RegExp(
    r'(?<![\u1000-\u104f])[\u1000-\u1021]\u103a|'
    r'[\u1000-\u1021]\u1031|'
    r'[\u1000-\u1021][\u102b-\u1030]\u103a|'
    r'[\u1000-\u1021]\u103a[\u1038\u102b-\u1030]',
  );

  /// Returns true when [input] contains Zawgyi-encoded Myanmar characters.
  static bool isZawgyi(String input) {
    if (input.isEmpty) return false;
    return _zgPattern.hasMatch(input);
  }

  // Per-string font cache: high-frequency WebSocket updates reuse the same
  // payloads (team names, odds labels) over and over, so re-running regex
  // detection on every build frame would waste CPU on scrolling tables.
  // Safe to share with the async framework because detection is stateless.
  static const int _cacheCap = 512;
  static final Map<String, String> _familyCache = {};

  static String fontFamilyFor(String input) {
    if (input.isEmpty) return unicodeFontFamily;
    final cached = _familyCache[input];
    if (cached != null) return cached;
    if (_familyCache.length >= _cacheCap) _familyCache.clear();
    final family = isZawgyi(input) ? _zawgyiFontFamily : unicodeFontFamily;
    _familyCache[input] = family;
    return family;
  }

  static const String _zawgyiFontFamily = 'Zawgyi-One';
  static const String unicodeFontFamily = 'Pyidaungsu';

  /// Returns a [TextStyle] with the correct font family set:
  ///   * `'Zawgyi-One'` when Zawgyi is detected.
  ///   * `'Pyidaungsu'` (Unicode Myanmar) otherwise.
  static TextStyle getCorrectStyle(String input, {TextStyle? baseStyle}) {
    final style = baseStyle ?? const TextStyle();
    return style.copyWith(fontFamily: fontFamilyFor(input));
  }

  /// Convenience widget that renders a single line of Burmese text with
  /// automatic font-family detection.
  static Widget renderText(
    String text, {
    TextStyle? style,
    TextAlign align = TextAlign.start,
    int? maxLines,
    TextOverflow? overflow,
  }) {
    return Text(
      text,
      textAlign: align,
      maxLines: maxLines,
      overflow: overflow,
      style: getCorrectStyle(text, baseStyle: style),
    );
  }
}