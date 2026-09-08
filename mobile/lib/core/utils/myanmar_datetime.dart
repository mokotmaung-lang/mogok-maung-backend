/// Myanmar locale helpers — UTC storage, MMT (+6:30) display, Myanmar numerals.
///
/// Spec reference: "Localization Strategy" — backend stores UTC, the mobile
/// layer converts to Myanmar Standard Time and renders Myanmar digits, e.g.
/// "၀၉:၃၀ နံနက်".
library;

/// Myanmar Standard Time offset (UTC + 06:30).
const Duration myanmarTimezoneOffset = Duration(hours: 6, minutes: 30);

const List<String> _myanmarDigits = [
  '၀', '၁', '၂', '၃', '၄', '၅', '၆', '၇', '၈', '၉',
];

const List<String> myanmarMonths = [
  'ဇန်နဝါရီ', 'ဖေဖော်ဝါရီ', 'မတ်', 'ဧပြီ', 'မေ', 'ဇွန်',
  'ဇူလိုင်', 'ဩဂုတ်', 'စက်တင်ဘာ', 'အောက်တိုဘာ', 'နိုဝင်ဘာ', 'ဒီဇင်ဘာ',
];

/// Converts [input]'s ASCII digits 0-9 into Myanmar numerals, leaving the
/// rest of the string untouched.
String toMyanmarDigits(String input) {
  final buffer = StringBuffer();
  for (final rune in input.runes) {
    if (rune >= 0x30 && rune <= 0x39) {
      buffer.write(_myanmarDigits[rune - 0x30]);
    } else {
      buffer.writeCharCode(rune);
    }
  }
  return buffer.toString();
}

/// Converts a UTC [DateTime] to Myanmar Standard Time.
DateTime toMyanmarTime(DateTime utc) => utc.toUtc().add(myanmarTimezoneOffset);

/// Renders [value] with ASCII thousand separators plus Myanmar numerals,
/// e.g. 500000.50 -> "၅၀၀,၀၀၀.၅၀".
String formatMyanmarNumber(double value) {
  final parts = value.toStringAsFixed(2).split('.');
  final intPart = parts[0];
  final out = StringBuffer();
  for (var i = 0; i < intPart.length; i++) {
    if (i > 0 && (intPart.length - i) % 3 == 0) out.write(',');
    out.write(intPart[i]);
  }
  final result = parts.length > 1 ? '$out.${parts[1]}' : out.toString();
  return toMyanmarDigits(result);
}

/// Day-part word for a 24-hour hour value (Myanmar convention).
String myanmarDayPart(int hour24) {
  if (hour24 < 12) return 'နံနက်';
  if (hour24 == 12) return 'နေ့လယ်';
  if (hour24 <= 16) return 'ညနေ';
  if (hour24 <= 18) return 'နေဝင်ရီတရော';
  return 'ည';
}

/// Renders a time-of-day as "HH:MM နံနက်" in Myanmar numerals.
/// Input may be UTC or local; the result is always MMT first, using the
/// caller's [DateTime] directly (already converted with [toMyanmarTime]).
String formatMyanmarClock(DateTime time) {
  final hh = time.hour.toString().padLeft(2, '0');
  final mm = time.minute.toString().padLeft(2, '0');
  return '${toMyanmarDigits('$hh:$mm')} ${myanmarDayPart(time.hour)}';
}

/// Renders a full date-time for UI:
/// "2026 ဇူလိုင် 7, ၀၉:၃၀ နံနက်" (converted from UTC to MMT).
String formatMyanmarDateTime(DateTime utc) {
  final local = toMyanmarTime(utc);
  final year = toMyanmarDigits(local.year.toString());
  final day = toMyanmarDigits(local.day.toString());
  final date = '$year ${myanmarMonths[local.month - 1]} $day';
  return '$date, ${formatMyanmarClock(local)}';
}