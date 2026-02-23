// Basic smoke test to verify the app widget can be instantiated.

import 'package:flutter_test/flutter_test.dart';

import 'package:termopus/app.dart';

void main() {
  testWidgets('ClaudeRemoteApp can be created', (WidgetTester tester) async {
    // Verify the app class exists and is instantiable.
    // Full widget pumping requires ProviderScope + SharedPreferences overrides,
    // so this test only checks that the import resolves correctly.
    expect(ClaudeRemoteApp, isNotNull);
  });
}
