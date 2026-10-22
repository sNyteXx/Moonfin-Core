import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/custom/hidden_vault/data/vault_config_sync.dart';
import 'package:moonfin/custom/hidden_vault/model/vault_config.dart';
import 'package:server_jellyfin/src/api/jellyfin_display_preferences_api.dart';

const _unrelatedPrefs = <String, String?>{
  'tvhome': null,
  'dashboardTheme': null,
  'skipForwardLength': '30000',
  'empty': '',
};

/// Supplies wire JSON so the real Dio transport decoding and Jellyfin API
/// mapping run, including serialization of the preferences saved by the vault.
class _DisplayPreferencesServer implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  Map<String, dynamic>? saved;
  Map<String, dynamic> response = {
    'Id': 'f3cc046a-97da-4ad5-8a9e-a7f330ff8421',
    'SortBy': 'SortName',
    'SortOrder': 'Ascending',
    'ViewType': null,
    'CustomPrefs': {..._unrelatedPrefs},
  };

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (options.method == 'GET') {
      return ResponseBody.fromString(
        jsonEncode(response),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    if (options.method == 'POST') {
      final bytes = await requestStream!.fold<List<int>>(
        [],
        (bytes, chunk) => bytes..addAll(chunk),
      );
      saved = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      response = saved!;
      return ResponseBody.fromString('', 204);
    }
    throw StateError('Unexpected request: ${options.method} ${options.path}');
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  for (final configIsNull in [false, true]) {
    test(
      'vault sync preserves preferences with ${configIsNull ? 'null' : 'absent'} config',
      () async {
        final server = _DisplayPreferencesServer();
        if (configIsNull) {
          (server.response['CustomPrefs'] as Map)[VaultConfigSync.key] = null;
        }
        final dio = Dio(BaseOptions(baseUrl: 'http://jellyfin.invalid'))
          ..httpClientAdapter = server;
        addTearDown(dio.close);
        final api = JellyfinDisplayPreferencesApi(dio);
        final sync = VaultConfigSync(() => api);
        final config = VaultConfig(
          vaults: [
            VaultDefinition(
              id: 'vault-1',
              name: 'Private',
              libraries: [
                VaultLibrary(
                  libraryId: 'library-1',
                  name: 'Movies',
                  tags: ['hidden'],
                ),
              ],
            ),
          ],
          settings: const VaultSettings(hideWatched: true),
          revision: 3,
          updatedAt: 1792663200000,
        );

        // A fresh Jellyfin response has no config yet, but does contain null
        // preferences. This must not fail before the first vault save.
        expect(await sync.pull(), isNull);
        await sync.push(config);

        expect(server.saved?['CustomPrefs'], {
          ..._unrelatedPrefs,
          VaultConfigSync.key: config.encode(),
        });
        expect(server.saved?['Id'], 'f3cc046a-97da-4ad5-8a9e-a7f330ff8421');
        expect(server.saved?['SortBy'], 'SortName');
        expect(server.saved?['SortOrder'], 'Ascending');

        final restored = await sync.pull();
        expect(restored?.toJson(), config.toJson());
        expect(server.requests.map((request) => request.method), [
          'GET',
          'GET',
          'POST',
          'GET',
        ]);
        for (final request in server.requests) {
          expect(
            request.path,
            '/DisplayPreferences/${VaultConfigSync.preferencesId}',
          );
          expect(request.queryParameters, {'client': VaultConfigSync.client});
        }
      },
    );
  }
}
