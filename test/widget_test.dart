// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';

import 'package:sleepwell/main.dart';

void main() {
  testWidgets('shows onboarding first', (WidgetTester tester) async {
    await tester.pumpWidget(const SleepWellApp(enableAudio: false));
    expect(find.text('Welcome'), findsOneWidget);
    expect(find.text("Let's begin your journey to peaceful sleep"), findsOneWidget);
  });
}
