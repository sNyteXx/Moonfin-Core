// Read-only smoke test of the hidden content vault's server queries against
// a real Jellyfin. Sends GET requests only; changes nothing on the server.
//
//   dart run tool/hidden_vault_smoke.dart \
//     --server http://tower:8096 --token <access token> --user <user id> \
//     --rule <libraryId>=ecchi[,private] [--rule <libraryId>=...]
//
// Checks, per configured library:
//   * how Jellyfin combines several tags (expects "any of", i.e. OR)
//   * how many server matches the exact client check drops
//   * what the hidden index build costs (requests, ms, ids)
//   * how many items carry the same tags outside the configured libraries
//     (they must stay visible: library scope)
// and how many Next Up episodes the filter would remove through their series.
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:moonfin/custom/hidden_vault/model/tag_match.dart';

Future<void> main(List<String> args) async {
  String? server;
  String? token;
  String? user;
  final rules = <String, List<String>>{};
  for (var i = 0; i < args.length; i++) {
    final next = i + 1 < args.length ? args[i + 1] : null;
    switch (args[i]) {
      case '--server':
        server = next;
        i++;
      case '--token':
        token = next;
        i++;
      case '--user':
        user = next;
        i++;
      case '--rule':
        final parts = (next ?? '').split('=');
        if (parts.length == 2) {
          rules[parts[0]] = parts[1].split(',').map((t) => t.trim()).toList();
        }
        i++;
    }
  }
  if (server == null || token == null || user == null || rules.isEmpty) {
    stderr.writeln(
      'usage: dart run tool/hidden_vault_smoke.dart --server URL --token TOKEN '
      '--user USER_ID --rule LIBRARY_ID=tag1[,tag2] [--rule ...]',
    );
    exitCode = 64;
    return;
  }

  final dio = Dio(
    BaseOptions(
      baseUrl: server,
      headers: {'X-Emby-Token': token},
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 60),
    ),
  );
  var requests = 0;

  Future<Map<String, dynamic>> items(Map<String, Object?> query) async {
    requests++;
    final response = await dio.get<Map<String, dynamic>>(
      '/Users/$user/Items',
      queryParameters: {
        for (final e in query.entries)
          if (e.value != null) e.key: e.value,
      },
    );
    return response.data ?? const {};
  }

  Future<Set<String>> ids(Map<String, Object?> query) async {
    final result = <String>{};
    var start = 0;
    while (true) {
      final page = await items({...query, 'StartIndex': start, 'Limit': 1000});
      final list = (page['Items'] as List?) ?? const [];
      for (final item in list) {
        result.add((item as Map)['Id'].toString());
      }
      start += list.length;
      if (list.length < 1000) break;
    }
    return result;
  }

  final info = await dio.get<Map<String, dynamic>>('/System/Info/Public');
  stdout.writeln(
    'Server: ${info.data?['ServerName']} ${info.data?['ProductName'] ?? ''} '
    '${info.data?['Version']}',
  );

  final hiddenIds = <String>{};
  for (final entry in rules.entries) {
    final library = entry.key;
    final tags = entry.value;
    final normalized = normalizeTags(tags);
    stdout.writeln('\nLibrary $library, tags $tags');

    // Several tags: one query per tag versus one with all of them.
    final perTag = <String, Set<String>>{};
    for (final tag in tags) {
      perTag[tag] = await ids({
        'ParentId': library,
        'Recursive': true,
        'Tags': tag,
        'ImageTypeLimit': 0,
      });
      stdout.writeln('  Tags=$tag: ${perTag[tag]!.length} items');
    }
    if (tags.length > 1) {
      final union = perTag.values.expand((s) => s).toSet();
      final combined = await ids({
        'ParentId': library,
        'Recursive': true,
        'Tags': tags.join('|'),
        'ImageTypeLimit': 0,
      });
      final semantics = combined.length == union.length
          ? 'OR (any tag)'
          : (combined.length < union.length ? 'AND?' : 'unexpected');
      stdout.writeln(
        '  Tags=${tags.join('|')}: ${combined.length} items, '
        'union of single tags ${union.length} -> $semantics',
      );
    }

    // The index build as the app does it, with exact validation.
    final before = requests;
    final watch = Stopwatch()..start();
    var start = 0;
    var kept = 0;
    final rejected = <String>{};
    while (true) {
      final page = await items({
        'ParentId': library,
        'Recursive': true,
        'Tags': tags.join('|'),
        'Fields': 'Tags',
        'SortBy': 'SortName',
        'ImageTypeLimit': 0,
        'EnableTotalRecordCount': true,
        'StartIndex': start,
        'Limit': 1000,
      });
      final list = (page['Items'] as List?) ?? const [];
      for (final raw in list.cast<Map>()) {
        final itemTags = extractTags(raw) ?? const [];
        if (matchesAnyTag(itemTags, normalized)) {
          kept++;
          hiddenIds.add(raw['Id'].toString());
        } else {
          rejected.add('${raw['Name']} ${itemTags.join(', ')}');
        }
      }
      start += list.length;
      if (list.length < 1000) break;
    }
    watch.stop();
    stdout.writeln(
      '  index build: ${requests - before} request(s), '
      '${watch.elapsedMilliseconds} ms, $kept hidden, '
      '${rejected.length} dropped by exact matching',
    );
    for (final r in rejected.take(10)) {
      stdout.writeln('    dropped: $r');
    }

    // Library scope: the same tags elsewhere stay visible.
    final everywhere = await ids({
      'Recursive': true,
      'Tags': tags.join('|'),
      'ImageTypeLimit': 0,
    });
    final inScope = perTag.values.expand((s) => s).toSet();
    stdout.writeln(
      '  same tags outside this library: '
      '${everywhere.difference(inScope).length} item(s) (stay visible)',
    );
  }

  // Episodes the filter would remove through their series.
  requests++;
  final nextUp = await dio.get<Map<String, dynamic>>(
    '/Shows/NextUp',
    queryParameters: {'UserId': user, 'Limit': 100, 'Fields': 'SeriesId'},
  );
  final episodes = (nextUp.data?['Items'] as List?) ?? const [];
  final hiddenEpisodes = episodes
      .cast<Map>()
      .where((e) => hiddenIds.contains(e['SeriesId']?.toString()))
      .length;
  stdout.writeln(
    '\nNext Up: ${episodes.length} episodes, $hiddenEpisodes belong to hidden '
    'series and would be filtered (no request per episode).',
  );
  stdout.writeln('Total GET requests: $requests');
}
