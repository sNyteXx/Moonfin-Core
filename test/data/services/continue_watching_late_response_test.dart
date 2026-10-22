import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moonfin/data/models/home_row.dart';
import 'package:moonfin/data/services/row_data_source.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:server_core/server_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockClient extends Mock implements MediaServerClient {}

class _MockItemsApi extends Mock implements ItemsApi {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockItemsApi api;
  late RowDataSource source;

  const response = {
    'Items': [
      {'Id': 'episode', 'Name': 'Episode', 'Type': 'Episode'},
    ],
    'TotalRecordCount': 1,
  };

  Future<Map<String, dynamic>> resumeCall() => api.getResumeItems(
    parentId: any(named: 'parentId'),
    includeItemTypes: any(named: 'includeItemTypes'),
    mediaTypes: any(named: 'mediaTypes'),
    startIndex: any(named: 'startIndex'),
    limit: any(named: 'limit'),
    fields: any(named: 'fields'),
    enableImageTypes: any(named: 'enableImageTypes'),
    imageTypeLimit: any(named: 'imageTypeLimit'),
  );

  Future<Map<String, dynamic>> nextUpCall() => api.getNextUp(
    parentId: any(named: 'parentId'),
    startIndex: any(named: 'startIndex'),
    limit: any(named: 'limit'),
    fields: any(named: 'fields'),
    enableImageTypes: any(named: 'enableImageTypes'),
    imageTypeLimit: any(named: 'imageTypeLimit'),
    enableResumable: any(named: 'enableResumable'),
    nextUpDateCutoff: any(named: 'nextUpDateCutoff'),
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final store = PreferenceStore();
    await store.init();
    GetIt.instance.registerSingleton<UserPreferences>(UserPreferences(store));
    api = _MockItemsApi();
    final client = _MockClient();
    when(() => client.itemsApi).thenReturn(api);
    source = RowDataSource(client);
    when(
      () => api.getItems(
        includeItemTypes: any(named: 'includeItemTypes'),
        filters: any(named: 'filters'),
        recursive: any(named: 'recursive'),
        sortBy: any(named: 'sortBy'),
        sortOrder: any(named: 'sortOrder'),
        limit: any(named: 'limit'),
        fields: any(named: 'fields'),
      ),
    ).thenAnswer((_) async => {'Items': <dynamic>[]});
  });

  tearDown(() => GetIt.instance.reset());

  for (final nextUp in [false, true]) {
    final label = nextUp ? 'Next Up' : 'Resume';
    Future<Map<String, dynamic>> call() => nextUp ? nextUpCall() : resumeCall();
    Future<HomeRow> load() =>
        nextUp ? source.loadNextUp('server') : source.loadResume('server');

    testWidgets(
      '$label keeps a slow successful request without launching duplicates',
      (tester) async {
        final pending = Completer<Map<String, dynamic>>();
        var requests = 0;
        when(call).thenAnswer((_) {
          requests++;
          return pending.future;
        });
        HomeRow? result;
        Object? failure;
        load().then<void>(
          (row) {
            result = row;
          },
          onError: (Object e) {
            failure = e;
          },
        );

        // A cold Vault index and a large Jellyfin catalog can take longer
        // than the former 8-second request plus 6-second duplicate request.
        await tester.pump(const Duration(seconds: 35));
        expect(requests, 1);
        expect(failure, isNull);
        expect(result, isNull);

        pending.complete(response);
        await tester.pump();
        expect(result?.items.map((item) => item.id), ['episode']);
        expect(failure, isNull);
      },
    );

    test(
      '$label still retries reduced fields after an actual server error',
      () async {
        var requests = 0;
        when(call).thenAnswer((_) async {
          requests++;
          if (requests == 1) {
            final options = RequestOptions(path: '/items');
            throw DioException.badResponse(
              statusCode: 500,
              requestOptions: options,
              response: Response(requestOptions: options, statusCode: 500),
            );
          }
          return response;
        });

        expect((await load()).items.single.id, 'episode');
        expect(requests, 2);
      },
    );

    test(
      '$label propagates a real network timeout without a duplicate',
      () async {
        var requests = 0;
        final timeout = DioException.receiveTimeout(
          timeout: const Duration(minutes: 1),
          requestOptions: RequestOptions(path: '/items'),
        );
        when(call).thenAnswer((_) async {
          requests++;
          throw timeout;
        });

        await expectLater(load(), throwsA(same(timeout)));
        expect(requests, 1);
      },
    );
  }
}
