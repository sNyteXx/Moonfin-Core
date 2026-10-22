import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/custom/hidden_vault/data/hidden_content_service.dart';
import 'package:moonfin/custom/hidden_vault/data/visibility_items_api.dart';
import 'package:moonfin/custom/hidden_vault/data/vault_store.dart';

import 'harness.dart';

void main() {
  Future<Harness> configured() async {
    final h = Harness()..seedStandard();
    await h.configure();
    addTearDown(() => h.service.dispose());
    // Establish authoritative visible checks before simulating a partial
    // outage. A failed lookup must not hide these unrelated known items.
    expect(idsOf(await h.api.getNextUp(limit: 15)), ['a5e1', 's1e1']);
    return h;
  }

  Map<String, dynamic> addEpisode(
    Harness h,
    String seriesId, {
    List<String> tags = const ['Ecchi'],
  }) {
    h.server.series('lib-anime', seriesId, tags: tags);
    return h.server.episode(
      'lib-anime',
      '$seriesId-e1',
      seriesId: seriesId,
      nextUp: true,
    );
  }

  group('unavailable tag checks', () {
    test(
      'a failed multi-ID batch withholds only unresolved items and retries',
      () async {
        final h = await configured();
        final hidden = addEpisode(h, 'new-hidden');
        final visible = addEpisode(h, 'new-visible', tags: []);
        h.server.tagLookupError = StateError('tag endpoint unavailable');

        // More than one ID also checks that every failed batch future has an
        // error handler; flutter_test rejects unhandled asynchronous errors.
        expect(idsOf(await h.api.getNextUp(limit: 15)), ['a5e1', 's1e1']);
        for (final raw in [hidden, visible]) {
          expect(h.service.verdictOf(raw).kind, VerdictKind.unavailable);
          expect(h.service.isHiddenNow(raw), isTrue);
        }

        h.server.tagLookupError = null;
        expect(idsOf(await h.api.getNextUp(limit: 15)), [
          'a5e1',
          's1e1',
          'new-visible-e1',
        ]);
        expect(h.service.verdictOf(hidden).kind, VerdictKind.hidden);
        expect(h.service.verdictOf(visible).kind, VerdictKind.visible);
        expect(h.service.isHiddenNow(visible), isFalse);
      },
    );

    for (final missingMetadata in [false, true]) {
      test('${missingMetadata ? 'missing Tags' : 'a missing response ID'} '
          'is not cached as an empty tag list', () async {
        final h = await configured();
        final episode = addEpisode(h, 'new-series', tags: []);
        final omitted = missingMetadata
            ? h.server.omitTagMetadataIds
            : h.server.omitTagLookupIds;
        omitted.add('new-series');

        expect(idsOf(await h.api.getNextUp(limit: 15)), ['a5e1', 's1e1']);
        expect(h.service.verdictOf(episode).kind, VerdictKind.unavailable);

        omitted.clear();
        expect(idsOf(await h.api.getNextUp(limit: 15)), [
          'a5e1',
          's1e1',
          'new-series-e1',
        ]);
        expect(h.service.verdictOf(episode).kind, VerdictKind.visible);
      });
    }

    test(
      'pending and failed are distinct and neither authorizes visibility',
      () async {
        final h = await configured();
        final episode = addEpisode(h, 'pending-series');
        final gate = Completer<void>();
        h.server.tagLookupGate = gate;
        final pending = h.api.getNextUp(limit: 15);
        await Future<void>.delayed(Duration.zero);

        expect(h.service.verdictOf(episode).kind, VerdictKind.unknown);
        expect(h.service.isHiddenNow(episode), isTrue);
        h.server.tagLookupError = StateError('lookup failed');
        gate.complete();

        expect(idsOf(await pending), ['a5e1', 's1e1']);
        expect(h.service.verdictOf(episode).kind, VerdictKind.unavailable);
      },
    );

    test(
      'the service timeout withholds the item without poisoning a retry',
      () async {
        final h = await configured();
        final episode = addEpisode(h, 'slow-series', tags: []);
        final gate = Completer<void>();
        h.server.tagLookupGate = gate;

        expect(idsOf(await h.api.getNextUp(limit: 15)), ['a5e1', 's1e1']);
        expect(h.service.verdictOf(episode).kind, VerdictKind.unavailable);

        gate.complete();
        h.server.tagLookupGate = null;
        expect(idsOf(await h.api.getNextUp(limit: 15)), [
          'a5e1',
          's1e1',
          'slow-series-e1',
        ]);
        expect(h.service.verdictOf(episode).kind, VerdictKind.visible);
      },
    );

    test(
      'detail access stays refused even inside an unrelated open vault',
      () async {
        final h = await configured();
        addEpisode(h, 'new-series');
        h.server.tagLookupError = StateError('lookup failed');
        h.context.enteredVaults = {'anime', 'shows'};

        await expectLater(
          h.api.getItem('new-series-e1'),
          throwsA(isA<HiddenContentRefusal>()),
        );
        expect((await h.api.getItem('a5'))['Id'], 'a5');

        h.server.tagLookupError = null;
        expect((await h.api.getItem('new-series-e1'))['Id'], 'new-series-e1');
      },
    );

    test(
      'a restart does not turn a failed check into visible content',
      () async {
        final h = await configured();
        final episode = addEpisode(h, 'new-series');
        h.server.tagLookupError = StateError('lookup failed');
        await h.api.getNextUp(limit: 15);
        expect(h.service.verdictOf(episode).kind, VerdictKind.unavailable);

        h.service.dispose();
        h.restart();
        expect(h.service.verdictOf(episode).kind, VerdictKind.unknown);
        expect(h.service.isHiddenNow(episode), isTrue);
        expect(
          idsOf(await h.api.getNextUp(limit: 15)),
          isNot(contains('new-series-e1')),
        );
      },
    );

    test(
      'legacy negative checks cannot authorize visibility after upgrade',
      () async {
        final h = await configured();
        final episode = addEpisode(h, 'new-series');
        h.service.dispose();
        await h.store.setString(
          VaultStorageKeys.checks(scope),
          jsonEncode({
            'fp': h.service.fingerprint,
            'c': {
              'new-series': [0, h.now.millisecondsSinceEpoch ~/ 1000],
            },
            'o': <String>[],
          }),
        );
        h.restart();

        expect(h.service.verdictOf(episode).kind, VerdictKind.unknown);
        expect(h.service.isHiddenNow(episode), isTrue);
        expect(
          idsOf(await h.api.getNextUp(limit: 15)),
          isNot(contains('new-series-e1')),
        );
        expect(h.service.verdictOf(episode).kind, VerdictKind.hidden);
      },
    );

    test(
      'verified untagged movies remain available to synchronous checks',
      () async {
        final h = await configured();
        await h.api.getItem('f3');
        expect(
          h.service.verdictOf({'Id': 'f3', 'Type': 'Movie'}).kind,
          VerdictKind.visible,
        );
      },
    );
  });
}
