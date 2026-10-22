import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:moonfin/custom/hidden_vault/ui/widgets/vault_card_metrics.dart';
import 'package:moonfin/custom/hidden_vault/ui/widgets/vault_item_card.dart';
import 'package:moonfin/data/models/aggregated_item.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:moonfin/ui/theme/app_theme.dart';
import 'package:moonfin/ui/widgets/focus/locked_focus_row.dart';
import 'package:moonfin/ui/widgets/grid_button_card.dart';
import 'package:moonfin/util/focus/input_mode_tracker.dart';
import 'package:moonfin/util/platform_detection.dart';
import 'package:moonfin_design/moonfin_design.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'harness.dart';

void main() {
  setUp(() async {
    PlatformDetection.setTvMode(true);
    ThemeRegistry.setActiveById(ThemeRegistry.moonfinId);
    await GetIt.instance.reset();
    SharedPreferences.setMockInitialValues({});
    final store = PreferenceStore();
    await store.init();
    GetIt.instance.registerSingleton<UserPreferences>(UserPreferences(store));
  });

  tearDown(() async {
    PlatformDetection.setTvMode(false);
    await GetIt.instance.reset();
  });

  for (final kind in ['library grid', 'home row', 'library buttons']) {
    final lockedRow = kind != 'library grid';
    final libraryButtons = kind == 'library buttons';
    testWidgets('$kind has one marker after pointer to D-pad switch', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final firstNode = FocusNode();
      final secondNode = FocusNode();
      addTearDown(firstNode.dispose);
      addTearDown(secondNode.dispose);
      final metrics = VaultCardMetrics.of(landscape: libraryButtons);
      final items = [
        for (final id in ['first', 'second'])
          AggregatedItem(
            id: id,
            serverId: 'server',
            rawData: {'Name': id, 'Type': 'Movie'},
          ),
      ];
      final images = FakeImageApi();
      final Widget cards = lockedRow
          ? LockedFocusRow<AggregatedItem>(
              items: items,
              hubKey: 'vault-focus-regression-$kind',
              itemExtent: metrics.width,
              itemSpacing: metrics.spacing,
              height: metrics.rowHeight,
              autofocus: true,
              itemBuilder: (_, item, _, focused) => libraryButtons
                  ? GridButtonCard(
                      icon: Icons.video_library,
                        label: item.name,
                      width: metrics.width,
                      height: metrics.imageHeight,
                      externalIsFocused: focused,
                      onTap: () {},
                    )
                  : VaultItemCard(
                      item: item,
                      images: images,
                      metrics: metrics,
                      externalIsFocused: focused,
                    ),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < items.length; i++)
                  VaultItemCard(
                    item: items[i],
                    images: images,
                    metrics: metrics,
                    focusNode: i == 0 ? firstNode : secondNode,
                    autofocus: i == 0,
                  ),
              ],
            );

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.buildTheme(ThemeRegistry.active),
          home: Scaffold(
            body: InputModeTracker(child: Center(child: cards)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      List<bool> markedCards() => tester
          .widgetList<AnimatedScale>(find.byType(AnimatedScale))
          .map((scale) => scale.scale > 1)
          .toList();

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      final cardFinder = find.byType(
        libraryButtons ? GridButtonCard : VaultItemCard,
      );
      final firstCardCenter = tester.getCenter(cardFinder.first);
      await mouse.moveTo(firstCardCenter);
      await tester.pumpAndSettle();
      expect(markedCards(), [true, false]);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      if (lockedRow) {
        final row = tester.state<LockedFocusRowState<AggregatedItem>>(
          find.byType(LockedFocusRow<AggregatedItem>),
        );
        expect(row.hasFocusedItem, isTrue);
        expect(row.focusedIndex, 1);
      } else {
        expect(secondNode.hasFocus, isTrue);
      }
      expect(markedCards(), [false, true]);

      // Returning to the pointer transfers the single visual marker back;
      // its stationary hover state was not destroyed by remote navigation.
      await mouse.moveTo(firstCardCenter + const Offset(1, 0));
      await tester.pumpAndSettle();
      expect(markedCards(), [true, false]);
    });
  }
}
