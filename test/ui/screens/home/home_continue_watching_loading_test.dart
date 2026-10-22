import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moonfin/custom/hidden_vault/data/hidden_content_registry.dart';
import 'package:moonfin/custom/hidden_vault/data/visibility_media_server_client.dart';
import 'package:moonfin/custom/hidden_vault/data/vault_store.dart';
import 'package:moonfin/data/models/aggregated_item.dart';
import 'package:moonfin/data/models/home_row.dart';
import 'package:moonfin/data/repositories/multi_server_repository.dart';
import 'package:moonfin/data/services/plugin_sync_service.dart';
import 'package:moonfin/data/services/row_data_source.dart';
import 'package:moonfin/data/viewmodels/media_bar_view_model.dart';
import 'package:moonfin/preference/home_section_config.dart';
import 'package:moonfin/preference/preference_constants.dart';
import 'package:moonfin/preference/seerr_preferences.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:moonfin/ui/screens/home/home_view_model.dart';
import 'package:server_core/server_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../custom/hidden_vault/fake_server.dart';
import '../../../custom/hidden_vault/harness.dart' show standardConfig;

class _MockClient extends Mock implements MediaServerClient {}

class _MockRows extends Mock implements RowDataSource {}

class _MockMediaBar extends Mock implements MediaBarViewModel {}

class _MockMultiServer extends Mock implements MultiServerRepository {}

class _MockPluginSync extends Mock implements PluginSyncService {}

class _MockSeerrPreferences extends Mock implements SeerrPreferences {}

HomeRow _row(String id, List<String> itemIds) => HomeRow(
  id: id,
  title: id,
  rowType: id == 'resume' ? HomeRowType.resume : HomeRowType.nextUp,
  totalCount: itemIds.length,
  items: [
    for (final itemId in itemIds)
      AggregatedItem(
        id: itemId,
        serverId: 'http://server',
        rawData: {
          'Id': itemId,
          'Type': 'Episode',
          'Name': itemId,
          'Tags': <String>[],
          'UserData': {'PlaybackPositionTicks': id == 'resume' ? 100 : 0},
        },
      ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late UserPreferences prefs;
  late HomeViewModel vm;
  late MediaServerClient client;
  late _MockRows rows;
  late _MockMediaBar mediaBar;
  late _MockMultiServer multiServer;
  late Completer<HomeRow> resume;
  late Completer<HomeRow> nextUp;
  late int resumeRequests;

  void createViewModel() {
    vm = HomeViewModel(
      dataSource: rows,
      prefs: prefs,
      client: client,
      mediaBarViewModel: mediaBar,
      multiServerRepo: multiServer,
    );
    GetIt.instance.registerSingleton<MediaServerClient>(client);
    GetIt.instance.registerSingleton<HomeViewModel>(vm);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final store = PreferenceStore();
    await store.init();
    prefs = UserPreferences(store);
    await prefs.setHomeSectionsConfig(const [
      HomeSectionConfig(type: HomeSectionType.resume),
      HomeSectionConfig(type: HomeSectionType.nextUp, order: 1),
    ]);
    await prefs.set(
      UserPreferences.lastExternalRowsRefreshTime,
      DateTime.now().millisecondsSinceEpoch,
    );
    GetIt.instance.registerSingleton<UserPreferences>(prefs);
    final plugin = _MockPluginSync();
    when(() => plugin.seerrAvailable).thenReturn(false);
    GetIt.instance.registerSingleton<PluginSyncService>(plugin);
    GetIt.instance.registerSingleton<SeerrPreferences>(_MockSeerrPreferences());

    HiddenContentRegistry.debugReset(store: MemoryVaultStore());
    client = _MockClient();
    when(() => client.userId).thenReturn('user');
    when(() => client.baseUrl).thenReturn('http://server');
    mediaBar = _MockMediaBar();
    when(() => mediaBar.load(force: any(named: 'force')))
        .thenAnswer((_) async {});
    rows = _MockRows();
    multiServer = _MockMultiServer();
    resume = Completer<HomeRow>();
    nextUp = Completer<HomeRow>();
    resumeRequests = 0;
    when(() => rows.loadResume('http://server')).thenAnswer((_) {
      resumeRequests++;
      return resume.future;
    });
    when(() => rows.loadNextUp('http://server'))
        .thenAnswer((_) => nextUp.future);
    createViewModel();
  });

  tearDown(() async {
    if (!resume.isCompleted) resume.complete(_row('resume', []));
    if (!nextUp.isCompleted) nextUp.complete(_row('nextUp', []));
    await pumpEventQueue();
    vm.dispose();
    await GetIt.instance.reset();
    HiddenContentRegistry.debugReset();
  });

  List<String> visibleIds() => [
    for (final row in vm.rows)
      for (final item in row.items) item.id,
  ];

  test(
    'Resume appears while Next Up is pending and the late items join it',
    () async {
      await vm.load();
      resume.complete(_row('resume', ['supernatural']));
      await pumpEventQueue();

      expect(visibleIds(), ['supernatural']);
      expect(vm.rows.single.isLoading, isFalse);

      nextUp.complete(_row('nextUp', ['rome', 'supernatural']));
      await pumpEventQueue();

      expect(visibleIds().toSet(), {'supernatural', 'rome'});
      expect(
        vm.rows.single.items
            .firstWhere((i) => i.id == 'supernatural')
            .playbackPositionTicks,
        100,
      );
    },
  );

  test(
    'Next Up appears while Resume is pending and Resume wins duplicates',
    () async {
      await vm.load();
      nextUp.complete(_row('nextUp', ['rome', 'supernatural']));
      await pumpEventQueue();

      expect(visibleIds().toSet(), {'rome', 'supernatural'});
      expect(vm.rows.single.isLoading, isFalse);

      resume.complete(_row('resume', ['supernatural']));
      await pumpEventQueue();

      expect(visibleIds().toSet(), {'supernatural', 'rome'});
      expect(
        vm.rows.single.items
            .firstWhere((i) => i.id == 'supernatural')
            .playbackPositionTicks,
        100,
      );
    },
  );

  test(
    'an empty first source leaves a placeholder for the late source',
    () async {
      await vm.load();
      resume.complete(_row('resume', []));
      await pumpEventQueue();

      expect(vm.rows.single.isLoading, isTrue);

      nextUp.complete(_row('nextUp', ['rome']));
      await pumpEventQueue();

      expect(visibleIds(), ['rome']);
      expect(vm.rows.single.isLoading, isFalse);
    },
  );

  test(
    'a failed second source keeps the successfully loaded first source',
    () async {
      await vm.load();
      resume.complete(_row('resume', ['supernatural']));
      await pumpEventQueue();
      expect(visibleIds(), ['supernatural']);

      nextUp.completeError(TimeoutException('network response timed out'));
      await pumpEventQueue();

      expect(visibleIds(), ['supernatural']);
      expect(vm.rows.single.isLoading, isFalse);
    },
  );

  test(
    'two failed sources clear a cold placeholder instead of spinning',
    () async {
      await vm.load();
      resume.completeError(TimeoutException('resume timed out'));
      nextUp.completeError(TimeoutException('next up timed out'));
      await pumpEventQueue();

      expect(vm.rows, isEmpty);
    },
  );

  test(
    'a populated row stays visible while a refresh is only partly ready',
    () async {
      await vm.load();
      resume.complete(_row('resume', ['old-resume']));
      nextUp.complete(_row('nextUp', ['old-next-up']));
      await pumpEventQueue();

      resume = Completer<HomeRow>();
      nextUp = Completer<HomeRow>();
      final refresh = vm.refreshResumeAndNextUp();
      resume.complete(_row('resume', ['new-resume']));
      await pumpEventQueue();

      expect(visibleIds().toSet(), {'old-resume', 'old-next-up'});

      nextUp.complete(_row('nextUp', ['new-next-up']));
      await refresh;
      expect(visibleIds().toSet(), {'new-resume', 'new-next-up'});
    },
  );

  test(
    'the separate-row preference remains separate for late responses',
    () async {
      await prefs.set(UserPreferences.mergeContinueWatchingNextUp, false);
      final loading = vm.load();
      await pumpEventQueue();
      resume.complete(_row('resume', ['supernatural']));
      await pumpEventQueue();

      expect(vm.rows.first.id, 'resume');
      expect(vm.rows.first.items.single.id, 'supernatural');
      expect(vm.rows.last.id, 'nextUp');
      expect(vm.rows.last.isLoading, isTrue);

      nextUp.complete(_row('nextUp', ['rome']));
      await loading;

      expect(vm.rows.map((row) => row.id), ['resume', 'nextUp']);
      expect(visibleIds(), ['supernatural', 'rome']);
      expect(prefs.get(UserPreferences.mergeContinueWatchingNextUp), isFalse);
    },
  );

  test(
    'late results cannot publish after the active server client changed',
    () async {
      await vm.load();
      var updates = 0;
      vm.addListener(() => updates++);
      final otherClient = _MockClient();
      // Same user ID is not proof of the same server/session.
      when(() => otherClient.userId).thenReturn('user');
      when(() => otherClient.baseUrl).thenReturn('http://other-server');
      await GetIt.instance.unregister<MediaServerClient>();
      GetIt.instance.registerSingleton<MediaServerClient>(otherClient);

      resume.complete(_row('resume', ['old-server-item']));
      nextUp.complete(_row('nextUp', ['old-server-next-up']));
      await pumpEventQueue();

      expect(visibleIds(), isEmpty);
      expect(updates, 0);
    },
  );

  test('an unregistered view model ignores late results even when its client survives', () async {
    await vm.load();
    var updates = 0;
    vm.addListener(() => updates++);
    await GetIt.instance.unregister<HomeViewModel>();

    resume.complete(_row('resume', ['stale']));
    nextUp.complete(_row('nextUp', ['stale-next-up']));
    await pumpEventQueue();

    expect(visibleIds(), isEmpty);
    expect(updates, 0);
  });

  test(
    'a newer load queues a fresh merge instead of reviving older results',
    () async {
      await vm.load();
      final oldResume = resume;
      final oldNextUp = nextUp;
      resume = Completer<HomeRow>();
      nextUp = Completer<HomeRow>();

      await vm.load(preserveExisting: true, forceRefresh: true);
      expect(resumeRequests, 1); // No overlapping duplicate request.
      oldResume.complete(_row('resume', ['stale']));
      oldNextUp.complete(_row('nextUp', ['stale-next-up']));
      await pumpEventQueue();

      expect(visibleIds(), isEmpty);
      expect(vm.rows.single.isLoading, isTrue);
      expect(resumeRequests, 2); // The queued load is not silently discarded.

      resume.complete(_row('resume', ['fresh']));
      nextUp.complete(_row('nextUp', ['fresh-next-up']));
      await pumpEventQueue();
      expect(visibleIds().toSet(), {'fresh', 'fresh-next-up'});
    },
  );

  test(
    'a new Vault index cannot be undone by the second source arriving late',
    () async {
      final server = FakeJellyfin();
      server.movie('lib-shows', 'supernatural');
      server.movie('lib-shows', 'rome');
      final service = HiddenContentRegistry.instance.serviceFor(
        const VaultScope('server-1', 'user'),
        onlineApi: () => server,
      )!;
      await service.saveConfig(standardConfig());
      final fingerprint = service.fingerprint;
      final generation = service.generation;
      final guardedClient = VisibilityMediaServerClient(
        client,
        serverId: 'server-1',
        onlineItemsApi: () => server,
      );
      await GetIt.instance.unregister<HomeViewModel>();
      await GetIt.instance.unregister<MediaServerClient>();
      vm.dispose();
      client = guardedClient;
      createViewModel();

      await vm.load();
      resume.complete(_row('resume', ['supernatural']));
      await pumpEventQueue();
      expect(visibleIds(), ['supernatural']);

      server.movie('lib-shows', 'supernatural', tags: ['private']);
      await service.refreshIndex();
      expect(service.fingerprint, fingerprint);
      expect(service.generation, greaterThan(generation));
      nextUp.complete(_row('nextUp', ['rome']));
      await pumpEventQueue();

      expect(visibleIds(), ['rome']);
    },
  );

  for (final unregister in [true, false]) {
    test(
      'a late page cannot overwrite ${unregister ? 'an unregistered owner' : 'a refreshed row'}',
      () async {
        await vm.load();
        resume.complete(
          _row('resume', ['first-page']).copyWith(totalCount: 30),
        );
        nextUp.complete(_row('nextUp', []));
        await pumpEventQueue();
        final pageResume = Completer<HomeRow>();
        final pageNextUp = Completer<HomeRow>();
        when(() => rows.loadResume('http://server', startIndex: 15))
            .thenAnswer((_) => pageResume.future);
        when(() => rows.loadNextUp('http://server', startIndex: 15))
            .thenAnswer((_) => pageNextUp.future);
        final paging = vm.loadMoreForRow(0);

        if (unregister) {
          await GetIt.instance.unregister<HomeViewModel>();
        } else {
          resume = Completer<HomeRow>();
          nextUp = Completer<HomeRow>();
          await vm.load(preserveExisting: true, forceRefresh: true);
          resume.complete(_row('resume', ['fresh-first-page']));
          nextUp.complete(_row('nextUp', []));
          await pumpEventQueue();
        }
        var updates = 0;
        vm.addListener(() => updates++);
        pageResume.complete(_row('resume', ['obsolete-page']));
        pageNextUp.complete(_row('nextUp', []));
        await paging;

        expect(updates, 0);
        expect(visibleIds(), [unregister ? 'first-page' : 'fresh-first-page']);
      },
    );
  }
}
