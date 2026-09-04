import 'package:flutter_test/flutter_test.dart';

import 'package:navigate_phase1/main.dart';

void main() {
  testWidgets('fresh navigation app renders', (tester) async {
    await tester.pumpWidget(const NavigateApp());
    expect(find.text('Where to?'), findsOneWidget);
  });
}
