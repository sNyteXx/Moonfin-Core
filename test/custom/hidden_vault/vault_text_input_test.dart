import 'package:custom_tv_text_field/custom_tv_text_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:moonfin/custom/hidden_vault/ui/widgets/vault_text_input.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:moonfin/util/platform_detection.dart';
import 'package:shared_preferences/shared_preferences.dart';

// A focused field keeps blinking, so it never reaches pumpAndSettle's idle.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

void main() {
  late UserPreferences preferences;

  setUp(() async {
    PlatformDetection.setTvMode(true);
    await GetIt.instance.reset();
    SharedPreferences.setMockInitialValues({});
    final store = PreferenceStore();
    await store.init();
    preferences = UserPreferences(store);
    GetIt.instance.registerSingleton<UserPreferences>(preferences);
  });

  tearDown(() async {
    PlatformDetection.setTvMode(false);
    await GetIt.instance.reset();
  });

  Future<CustomTVTextFieldState> openField(
    WidgetTester tester,
    TextEditingController controller,
    List<String> submitted, {
    required bool systemIme,
    VoidCallback? onNavigateBack,
  }) async {
    await preferences.set(UserPreferences.preferSystemImeKeyboard, systemIme);
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Focus(
            onKeyEvent: (_, event) {
              if (onNavigateBack != null &&
                  event is KeyDownEvent &&
                  event.logicalKey == LogicalKeyboardKey.escape) {
                onNavigateBack();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: VaultTextInput(
              controller: controller,
              hint: 'Vault name',
              autofocus: true,
              onSubmitted: submitted.add,
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await _settle(tester);
    final field = tester.state<CustomTVTextFieldState>(
      find.byType(CustomTVTextField),
    );
    expect(field.isKeyboardVisible, isTrue);
    controller.selection = TextSelection.collapsed(
      offset: controller.text.length,
    );
    return field;
  }

  testWidgets('backspace edits with the system keyboard still open', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'abc');
    addTearDown(controller.dispose);
    final submitted = <String>[];
    final field = await openField(
      tester,
      controller,
      submitted,
      systemIme: true,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await _settle(tester);

    expect(controller.text, 'ab');
    expect(field.isKeyboardVisible, isTrue);
    expect(submitted, isEmpty);

    // The IME can echo the updated editing value; one press must still remove
    // only one character rather than deleting once per input path.
    tester.testTextInput.updateEditingValue(controller.value);
    await _settle(tester);
    expect(controller.text, 'ab');
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('system backspace keeps Flutter selection and Unicode editing', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'a\u{1F600}b');
    addTearDown(controller.dispose);
    final submitted = <String>[];
    final field = await openField(
      tester,
      controller,
      submitted,
      systemIme: true,
    );
    controller.selection = const TextSelection(baseOffset: 1, extentOffset: 3);

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await _settle(tester);

    expect(controller.text, 'ab');
    expect(controller.selection, const TextSelection.collapsed(offset: 1));
    expect(field.isKeyboardVisible, isTrue);
    expect(submitted, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('backspace edits in the app keyboard without submitting', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'abc');
    addTearDown(controller.dispose);
    final submitted = <String>[];
    final field = await openField(
      tester,
      controller,
      submitted,
      systemIme: false,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await _settle(tester);

    expect(controller.text, 'ab');
    expect(field.isKeyboardVisible, isTrue);
    expect(submitted, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  for (final systemIme in [false, true]) {
    testWidgets(
      'escape closes ${systemIme ? 'system' : 'app'} keyboard without saving',
      (tester) async {
        final controller = TextEditingController(text: 'existing vault');
        addTearDown(controller.dispose);
        final submitted = <String>[];
        var navigatedBack = 0;
        final field = await openField(
          tester,
          controller,
          submitted,
          systemIme: systemIme,
          onNavigateBack: () => navigatedBack++,
        );

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await _settle(tester);

        expect(controller.text, 'existing vault');
        expect(field.isKeyboardVisible, isFalse);
        expect(submitted, isEmpty);
        expect(find.byType(VaultTextInput), findsOneWidget);
        expect(navigatedBack, 0);

        // Once editing is closed, the next Back belongs to navigation.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await _settle(tester);
        expect(navigatedBack, 1);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }
}
