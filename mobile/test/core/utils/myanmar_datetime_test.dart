import 'package:flutter_test/flutter_test.dart';
import 'package:mogok_maung_mobile/core/utils/myanmar_datetime.dart';

void main() {
  group('toMyanmarDigits', () {
    test('converts ASCII digits to Myanmar numerals', () {
      expect(toMyanmarDigits('2026-07-07'), '၂၀၂၆-၀၇-၀၇');
    });

    test('non-digit characters pass through untouched', () {
      expect(toMyanmarDigits('v1.2x'), 'v၁.၂x');
    });

    test('empty input stays empty', () {
      expect(toMyanmarDigits(''), '');
    });
  });

  group('toMyanmarTime', () {
    test('adds the +06:30 offset', () {
      final mmt = toMyanmarTime(DateTime.utc(2026, 7, 7, 3, 0));
      expect(mmt.hour, 9);
      expect(mmt.minute, 30);
    });
  });

  group('formatMyanmarNumber', () {
    test('formats with thousand separators and Myanmar digits', () {
      expect(formatMyanmarNumber(500000.5), '၅၀၀,၀၀၀.၅၀');
    });

    test('small values keep two decimals', () {
      expect(formatMyanmarNumber(12), '၁၂.၀၀');
    });
  });

  group('myanmarDayPart', () {
    test('morning before noon', () {
      expect(myanmarDayPart(6), 'နံနက်');
      expect(myanmarDayPart(11), 'နံနက်');
    });

    test('noon', () {
      expect(myanmarDayPart(12), 'နေ့လယ်');
    });

    test('evening up to 16', () {
      expect(myanmarDayPart(15), 'ညနေ');
      expect(myanmarDayPart(16), 'ညနေ');
    });

    test('sunset band 17-18', () {
      expect(myanmarDayPart(17), 'နေဝင်ရီတရော');
      expect(myanmarDayPart(18), 'နေဝင်ရီတရော');
    });

    test('night after 18', () {
      expect(myanmarDayPart(19), 'ည');
      expect(myanmarDayPart(23), 'ည');
    });
  });

  group('formatMyanmarClock', () {
    test('pads hours and minutes to two digits with day-part', () {
      final t = DateTime(2026, 7, 7, 9, 5);
      expect(formatMyanmarClock(t), '၀၉:၀၅ နံနက်');
    });
  });

  group('formatMyanmarDateTime', () {
    test('renders a UTC instant in MMT with Myanmar numerals', () {
      final rendered =
          formatMyanmarDateTime(DateTime.utc(2026, 7, 7, 3, 0));
      expect(rendered, '၂၀၂၆ ဇူလိုင် ၇, ၀၉:၃၀ နံနက်');
    });
  });
}