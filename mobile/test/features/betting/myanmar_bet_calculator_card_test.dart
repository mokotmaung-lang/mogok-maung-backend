import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mogok_maung_mobile/features/betting/presentation/widgets/myanmar_bet_calculator_card.dart';

const _noLossOption = 'အရှုံးမရှိ (×1.00)';
const _oneFiftyOption = '၁-၅၀ (×1.50)';

Widget _wrap(Widget card) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: card)),
    );

Future<void> _selectLine(WidgetTester tester, String option) async {
  await tester.tap(find.byType(DropdownButtonFormField<MyanmarBetLine>));
  await tester.pumpAndSettle();
  await tester.tap(find.text(option).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders Burmese card with default no-loss line',
      (tester) async {
    await tester.pumpWidget(
      _wrap(const MyanmarBetCalculatorCard(availableBalance: 10000)),
    );

    expect(find.text('ကြေးတွက်စက်'), findsOneWidget);
    expect(find.text(_noLossOption), findsOneWidget);
    expect(find.text('လောင်းမည်'), findsOneWidget);
    expect(find.textContaining('လက်ကျန်'), findsOneWidget);
    expect(find.text('လောင်းကြေးထပ်ရန် ယူနစ် မလုံလောက်ပါ'), findsNothing);
  });

  testWidgets('live max-loss preview and submission — no-loss 1.00x',
      (tester) async {
    final submissions = <MyanmarBetSubmission>[];
    await tester.pumpWidget(
      _wrap(MyanmarBetCalculatorCard(
        availableBalance: 10000,
        onSubmit: submissions.add,
      )),
    );

    await tester.enterText(find.byType(TextField), '1000');
    await tester.pump();

    expect(find.text('1,000 ကျပ်'), findsOneWidget);
    expect(find.text('×1.00'), findsOneWidget);

    await tester.tap(find.text('လောင်းမည်'));
    expect(submissions, hasLength(1));
    expect(submissions.single.line, MyanmarBetLine.noLoss);
    expect(submissions.single.stakeCents, 100000);
    expect(submissions.single.kyat, 1000);
  });

  testWidgets('1.50x line preview is exact fixed point and highlighted',
      (tester) async {
    final submissions = <MyanmarBetSubmission>[];
    await tester.pumpWidget(
      _wrap(MyanmarBetCalculatorCard(
        availableBalance: 10000,
        onSubmit: submissions.add,
      )),
    );

    await tester.enterText(find.byType(TextField), '1000.50');
    await tester.pump();
    await _selectLine(tester, _oneFiftyOption);

    // 1000.50 × 1.50 = 1500.75 — exact cents, no float drift.
    expect(find.text('1,500.75 ကျပ်'), findsOneWidget);
    expect(find.text('×1.50'), findsOneWidget);

    await tester.tap(find.text('လောင်းမည်'));
    expect(submissions, hasLength(1));
    expect(submissions.single.line, MyanmarBetLine.oneFifty);
    expect(submissions.single.stakeCents, 100050);
  });

  testWidgets('blocks submission and warns when max loss exceeds balance',
      (tester) async {
    final submissions = <MyanmarBetSubmission>[];
    await tester.pumpWidget(
      _wrap(MyanmarBetCalculatorCard(
        availableBalance: 1000,
        onSubmit: submissions.add,
      )),
    );

    await tester.enterText(find.byType(TextField), '700');
    await tester.pump();
    await _selectLine(tester, _oneFiftyOption);

    // 700 × 1.50 = 1050 > 1000.
    expect(find.text('1,050 ကျပ်'), findsOneWidget);
    expect(find.text('လောင်းကြေးထပ်ရန် ယူနစ် မလုံလောက်ပါ'), findsOneWidget);

    final button = tester.widget<ElevatedButton>(
      find.byType(ElevatedButton),
    );
    expect(button.onPressed, isNull);

    await tester.tap(find.text('လောင်းမည်'), warnIfMissed: false);
    expect(submissions, isEmpty);
  });

  testWidgets('empty or non-numeric stake keeps confirm disabled',
      (tester) async {
    final submissions = <MyanmarBetSubmission>[];
    await tester.pumpWidget(
      _wrap(MyanmarBetCalculatorCard(
        availableBalance: 10000,
        onSubmit: submissions.add,
      )),
    );

    ElevatedButton button() =>
        tester.widget<ElevatedButton>(find.byType(ElevatedButton));

    expect(button().onPressed, isNull);
    expect(find.text('—'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '0');
    await tester.pump();
    expect(button().onPressed, isNull);

    await tester.enterText(find.byType(TextField), '12.345');
    await tester.pump();
    expect(find.text('1,234.50 ကျပ်'), findsNothing); // 12.345 rejected
    expect(button().onPressed, isNull);
  });
}