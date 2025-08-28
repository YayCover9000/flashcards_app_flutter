import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// IMPORTANT: this must match the `name:` in pubspec.yaml
import 'package:flashcards_app_flutter/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('app builds', (tester) async {
    // Provide mock store for SharedPreferences used by AppSettings/Store
    SharedPreferences.setMockInitialValues({});

    final settings = await AppSettings.load();
    await tester.pumpWidget(MyApp(settings: settings));
    await tester.pumpAndSettle();

    expect(find.text('My Decks'), findsOneWidget);
  });
}
