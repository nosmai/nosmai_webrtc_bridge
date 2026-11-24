import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nosmai_webrtc_bridge_example/main.dart';

void main() {
  testWidgets('setup page builds', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const ExampleApp());
    expect(find.text('Open sender (go live)'), findsOneWidget);
  });
}
