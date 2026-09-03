import 'package:flutter_test/flutter_test.dart';
import 'package:idr_navigation_app/main.dart';

void main() {
  testWidgets('IDR navigation app renders', (tester) async {
    await tester.pumpWidget(const IdrNavigationApp());
    expect(find.text('GPS ACTIVE'), findsWidgets);
    expect(find.text('SPEED'), findsOneWidget);
  });
}
