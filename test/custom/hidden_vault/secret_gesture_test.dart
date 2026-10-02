import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/ui/widgets/focus/hub_focus_memory.dart';
import 'package:moonfin/ui/widgets/focus/locked_focus_row.dart';
import 'package:moonfin/util/focus/key_event_utils.dart';

/// The hidden way into a vault: a 5 s hold of OK on a configured library
/// tile, while a short press still opens the library and every other tile
/// keeps its 500 ms context menu.
void main() {
  group('secret hold on library tiles', () {
    late List<String> taps;
    late List<String> longPresses;
    late List<String> holds;
    late FocusNode node;

    setUp(() {
      HubFocusMemory.clearAll();
      taps = [];
      longPresses = [];
      holds = [];
      node = FocusNode();
    });

    tearDown(() => node.dispose());

    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: LockedFocusRow<String>(
            items: const ['anime', 'music', 'shows'],
            hubKey: 'secret-hold-test',
            itemExtent: 100,
            height: 100,
            focusNode: node,
            itemBuilder: (context, item, index, isFocused) => Text(item),
            onTap: (_, item) => taps.add(item),
            onLongPress: (_, item) => longPresses.add(item),
            holdSelectEnabled: (item) => item == 'anime' || item == 'shows',
            onHoldSelect: (_, item) => holds.add(item),
          ),
        ),
      );
      node.requestFocus();
      await tester.pump();
    }

    Future<void> press(WidgetTester tester, Duration hold) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      await tester.pump(hold);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      await tester.pump();
    }

    testWidgets('normal tap opens the library', (tester) async {
      await pump(tester);
      await press(tester, const Duration(milliseconds: 120));
      expect(taps, ['anime']);
      expect(longPresses, isEmpty);
      expect(holds, isEmpty);
    });

    testWidgets('extra-long press asks for the PIN, nothing else', (
      tester,
    ) async {
      await pump(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      await tester.pump(const Duration(milliseconds: 4900));
      expect(holds, isEmpty, reason: 'not before 5 s');
      await tester.pump(const Duration(milliseconds: 200));
      expect(holds, ['anime']);
      // Still held: more repeats change nothing.
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
      await tester.pump(const Duration(seconds: 1));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(holds, ['anime']);
      expect(taps, isEmpty);
      expect(longPresses, isEmpty);
    });

    testWidgets('a medium press on a trigger tile still opens the menu, '
        'on release', (tester) async {
      await pump(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      await tester.pump(const Duration(milliseconds: 900));
      expect(longPresses, isEmpty, reason: 'decided on release');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(longPresses, ['anime']);
      expect(holds, isEmpty);
      expect(taps, isEmpty);
    });

    testWidgets('other tiles keep the 500 ms context menu', (tester) async {
      await pump(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      await tester.pump(const Duration(milliseconds: 600));
      // Fires while still held, exactly as before.
      expect(longPresses, ['music']);
      await tester.pump(const Duration(seconds: 6));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(holds, isEmpty);
      expect(taps, isEmpty);
    });

    testWidgets('the second trigger tile opens its own vault', (tester) async {
      await pump(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await press(tester, const Duration(milliseconds: 100));
      expect(taps, ['shows']);
      await press(tester, const Duration(milliseconds: 5100));
      expect(holds, ['shows']);
    });

    testWidgets('the menu key still opens the context menu', (tester) async {
      await pump(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pump();
      expect(longPresses, ['anime']);
    });

    testWidgets('losing focus mid-hold cancels it', (tester) async {
      await pump(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      await tester.pump(const Duration(milliseconds: 1000));
      node.unfocus();
      await tester.pump(const Duration(seconds: 5));
      expect(holds, isEmpty);
    });
  });

  group('rows without the option', () {
    testWidgets('behave exactly as before', (tester) async {
      final taps = <String>[];
      final longPresses = <String>[];
      final node = FocusNode();
      addTearDown(node.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: LockedFocusRow<String>(
            items: const ['a'],
            hubKey: 'plain',
            itemExtent: 100,
            height: 100,
            focusNode: node,
            itemBuilder: (context, item, index, isFocused) => Text(item),
            onTap: (_, item) => taps.add(item),
            onLongPress: (_, item) => longPresses.add(item),
          ),
        ),
      );
      node.requestFocus();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      await tester.pump(const Duration(milliseconds: 600));
      expect(longPresses, ['a']);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(taps, isEmpty);
    });
  });

  group('SelectHoldGesture', () {
    testWidgets('classifies presses by how long they were held', (
      tester,
    ) async {
      final gesture = SelectHoldGesture();
      var held = 0;
      gesture.down(() => held++);
      await tester.pump(const Duration(milliseconds: 100));
      expect(gesture.up(), SelectPressKind.tap);

      gesture.down(() => held++);
      await tester.pump(const Duration(milliseconds: 700));
      expect(gesture.up(), SelectPressKind.longPress);

      gesture.down(() => held++);
      await tester.pump(SelectHoldGesture.defaultHoldAfter);
      expect(held, 1);
      expect(gesture.up(), SelectPressKind.hold);
      expect(gesture.up(), SelectPressKind.none);
    });
  });
}
