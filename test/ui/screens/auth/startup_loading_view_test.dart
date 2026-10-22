import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:moonfin/ui/screens/auth/startup_loading_view.dart';

void main() {
  setUp(() async {
    await GetIt.instance.reset();
  });

  testWidgets('shows startup before services exist and can be replaced', (
    tester,
  ) async {
    await tester.pumpWidget(const StartupLoadingApp());

    expect(find.byType(StartupLoadingView), findsOneWidget);
    expect(find.bySemanticsLabel('Moonfin'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      isNull,
    );
    expect(tester.takeException(), isNull);

    // Bootstrap may still be waiting for storage or the platform channels.
    // The loading view must stay visible without starting any app services.
    await tester.pump(const Duration(seconds: 5));
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Ready'))),
    );
    await tester.pump();
    expect(find.text('Ready'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps the logo and loading bar within phone and TV bounds', (
    tester,
  ) async {
    addTearDown(() => tester.view.resetPhysicalSize());
    addTearDown(() => tester.view.resetDevicePixelRatio());
    tester.view.devicePixelRatio = 1;

    for (final size in [const Size(320, 568), const Size(1920, 1080)]) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(const StartupLoadingApp());
      await tester.pump();

      for (final finder in [
        find.byType(Image),
        find.byType(LinearProgressIndicator),
      ]) {
        final bounds = tester.getRect(finder);
        expect(bounds.width, greaterThan(0));
        expect(bounds.height, greaterThan(0));
        expect(bounds.left, greaterThanOrEqualTo(0));
        expect(bounds.top, greaterThanOrEqualTo(0));
        expect(bounds.right, lessThanOrEqualTo(size.width));
        expect(bounds.bottom, lessThanOrEqualTo(size.height));
      }
      expect(tester.takeException(), isNull);
    }
  });
}
