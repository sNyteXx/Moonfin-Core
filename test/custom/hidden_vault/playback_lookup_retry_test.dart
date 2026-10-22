import 'package:flutter_test/flutter_test.dart';
import 'package:playback_core/playback_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'play retries the selected pending check before filtering the queue',
    () async {
      final manager = PlaybackManager();
      addTearDown(manager.dispose);
      const selected = {'Id': 'selected', 'Type': 'Movie'};
      const unresolved = {'Id': 'unresolved', 'Type': 'Movie'};
      var verified = false;
      var unavailable = true;
      var lookups = 0;
      manager.setContentRefusal(
        queueFilter: (item) => !identical(item, selected) || !verified,
        playRefusal: (item) async {
          lookups++;
          if (unavailable) return true;
          verified = true;
          return false;
        },
      );

      await manager.playItems([selected, unresolved]);
      expect(lookups, 1);
      expect(manager.queueService.items, isEmpty);

      unavailable = false;
      await manager.playItems([selected, unresolved]);
      expect(lookups, 2);
      expect(manager.queueService.items, [selected]);
      // No backend is installed: this verifies authorization and queue setup,
      // without opening media or requiring a platform player in a unit test.
    },
  );

  test(
    'an async allowance cannot override a still-blocked synchronous gate',
    () async {
      final manager = PlaybackManager();
      addTearDown(manager.dispose);
      manager.setContentRefusal(
        queueFilter: (_) => true,
        playRefusal: (_) async => false,
      );

      await manager.playItems([
        {'Id': 'blocked', 'Type': 'Movie'},
      ]);

      expect(manager.queueService.items, isEmpty);
    },
  );
}
