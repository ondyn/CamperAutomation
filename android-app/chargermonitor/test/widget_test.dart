import 'package:flutter_test/flutter_test.dart';

import 'package:chargermonitor/main.dart';

void main() {
  testWidgets('app builds', (WidgetTester tester) async {
    await tester.pumpWidget(const ChargerMonitorApp());

    expect(find.text('Select Charger Device'), findsOneWidget);
  });
}
