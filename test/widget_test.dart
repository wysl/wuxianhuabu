import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wuxianhuabu/src/ui/connection_screen.dart';

/// Smoke tests for the shell.
///
/// The app restores a saved profile on launch, so `main()` is not pumped
/// directly: doing so would touch the real application-support directory. These
/// tests drive the connection screen, which is what a first launch shows.
void main() {
  Future<void> pumpConnectionScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: ConnectionScreen()),
      ),
    );
    await tester.pump();
  }

  testWidgets('connection screen asks for the things a connection needs', (
    tester,
  ) async {
    await pumpConnectionScreen(tester);

    expect(find.text('无界画布'), findsOneWidget);
    expect(find.text('地址'), findsOneWidget);
    expect(find.text('认证方式'), findsOneWidget);
    // The URL field is pre-filled with the local default, so the address appears
    // both as the field value and as its hint.
    expect(
      find.text('http://127.0.0.1:8188'),
      findsAtLeastNWidgets(1),
    );
    expect(find.text('连接并保存'), findsOneWidget);
    expect(find.text('仅测试'), findsOneWidget);
  });

  testWidgets('choosing Basic auth reveals the credential fields', (
    tester,
  ) async {
    await pumpConnectionScreen(tester);

    // The token field is shown for the default API-key strategy.
    expect(find.text('X-Api-Key'), findsOneWidget);

    await tester.tap(find.text('API Key（X-Api-Key）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('HTTP Basic').last);
    await tester.pumpAndSettle();

    expect(find.text('用户名'), findsOneWidget);
    expect(find.text('密码'), findsOneWidget);
    // ...and the token field is gone, so there is no ambiguity about which
    // credential is being sent.
    expect(find.text('X-Api-Key'), findsNothing);
  });

  testWidgets('choosing no auth explains why that is usually wrong', (
    tester,
  ) async {
    await pumpConnectionScreen(tester);

    await tester.tap(find.text('API Key（X-Api-Key）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('无认证').last);
    await tester.pumpAndSettle();

    expect(find.textContaining('ComfyUI 本身不提供认证'), findsOneWidget);
  });
}
