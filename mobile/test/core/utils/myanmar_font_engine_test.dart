import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mogok_maung_mobile/core/utils/myanmar_font_engine.dart';

void main() {
  group('MyanmarFontEngine.isZawgyi', () {
    test('empty string is never Zawgyi', () {
      expect(MyanmarFontEngine.isZawgyi(''), isFalse);
    });

    test('consonant followed by asat (U+103A) is Zawgyi', () {
      // \u1000 (က) + \u103A drawn as a trailing asat = zero-width Zawgyi form.
      expect(MyanmarFontEngine.isZawgyi('\u1000\u103A'), isTrue);
    });

    test('proper Unicode Myanmar greeting is not Zawgyi', () {
      expect(MyanmarFontEngine.isZawgyi('မြန်မာ'), isFalse);
    });

    test('ASCII input is not Zawgyi', () {
      expect(MyanmarFontEngine.isZawgyi('Mogok Maung FC'), isFalse);
    });
  });

  group('MyanmarFontEngine.fontFamilyFor', () {
    test('unicode text resolves to Pyidaungsu', () {
      expect(MyanmarFontEngine.fontFamilyFor('မြန်မာ'), 'Pyidaungsu');
    });

    test('empty input resolves to unicode family', () {
      expect(MyanmarFontEngine.fontFamilyFor(''), 'Pyidaungsu');
    });

    test('zawgyi text resolves to Zawgyi-One', () {
      expect(MyanmarFontEngine.fontFamilyFor('\u1000\u103A'), 'Zawgyi-One');
    });

    test('cached lookups return stable results (repeat reads)', () {
      const input = 'အားကစား';
      final first = MyanmarFontEngine.fontFamilyFor(input);
      expect(MyanmarFontEngine.fontFamilyFor(input), first);
    });
  });

  group('MyanmarFontEngine.getCorrectStyle', () {
    test('copies base style and sets the matched font family', () {
      const base = TextStyle(fontSize: 14, color: Colors.white);
      final styled = MyanmarFontEngine.getCorrectStyle('မြန်မာ', baseStyle: base);
      expect(styled.fontSize, 14);
      expect(styled.fontFamily, 'Pyidaungsu');
    });
  });
}