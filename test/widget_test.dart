///
/// Filename: c:\projects\lora_net\lora_net_app\test\widget_test.dart
/// Path: c:\projects\lora_net\lora_net_app\test
/// Created Date: Friday, February 14th 2026, 10:30:00 am
/// Author: Prashant Bhandari
/// Last Modified: Friday, February 14th 2026, 10:45:00 am
/// Modified By: Prashant Bhandari
/// 
/// Copyright (c) 2026 Electrophobia Tech
library;


// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_application_1/main.dart';

void main() {
  testWidgets('Counter increments smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const MyApp());

    // Verify that our counter starts at 0.
    expect(find.text('0'), findsOneWidget);
    expect(find.text('1'), findsNothing);

    // Tap the '+' icon and trigger a frame.
    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();

    // Verify that our counter has incremented.
    expect(find.text('0'), findsNothing);
    expect(find.text('1'), findsOneWidget);
  });
}
