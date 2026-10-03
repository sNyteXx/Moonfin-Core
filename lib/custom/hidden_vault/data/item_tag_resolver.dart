import 'dart:async';

import 'package:server_core/server_core.dart';

import '../model/tag_match.dart';

/// Looks up the tags of items by id, many at a time.
///
/// Every id asked for within the same turn of the event loop goes out in one
/// request (split only past [chunkSize]), and an id already on its way is not
/// asked for again. Twenty episodes from three series therefore cost one
/// request for the three series, never one per episode.
class ItemTagResolver {
  static const chunkSize = 100;

  final Future<Map<String, List<String>>> Function(List<String> ids) _fetch;

  final Map<String, Completer<List<String>?>> _inFlight = {};
  final Set<String> _queued = {};
  Timer? _flush;

  /// How many requests went out, for tests and the performance log.
  int requestCount = 0;

  ItemTagResolver(this._fetch);

  /// Uses [api] to read only the tags of each id.
  factory ItemTagResolver.forApi(ItemsApi Function() api) =>
      ItemTagResolver((ids) async {
        final response = await api().getItems(
          ids: ids,
          fields: 'Tags',
          imageTypeLimit: 0,
          enableTotalRecordCount: false,
        );
        final result = <String, List<String>>{};
        for (final raw in (response['Items'] as List?) ?? const []) {
          if (raw is! Map) continue;
          final id = raw['Id']?.toString() ?? '';
          if (id.isEmpty) continue;
          result[id] = extractTags(raw) ?? const [];
        }
        return result;
      });

  /// The tags of each of [ids]. An id the server didn't return (gone, or out
  /// of the user's reach) maps to null. Throws when the request fails.
  Future<Map<String, List<String>?>> resolve(Iterable<String> ids) async {
    final wanted = ids.where((id) => id.isNotEmpty).toSet();
    if (wanted.isEmpty) return const {};
    final futures = <String, Future<List<String>?>>{};
    for (final id in wanted) {
      final existing = _inFlight[id];
      if (existing != null) {
        futures[id] = existing.future;
        continue;
      }
      final completer = Completer<List<String>?>();
      _inFlight[id] = completer;
      _queued.add(id);
      futures[id] = completer.future;
    }
    _flush ??= Timer(Duration.zero, _send);
    final result = <String, List<String>?>{};
    for (final entry in futures.entries) {
      result[entry.key] = await entry.value;
    }
    return result;
  }

  Future<void> _send() async {
    _flush = null;
    final batch = _queued.toList();
    _queued.clear();
    for (var i = 0; i < batch.length; i += chunkSize) {
      final end = i + chunkSize > batch.length ? batch.length : i + chunkSize;
      final chunk = batch.sublist(i, end);
      requestCount++;
      try {
        final tags = await _fetch(chunk);
        for (final id in chunk) {
          _inFlight.remove(id)?.complete(tags[id]);
        }
      } catch (error, stack) {
        for (final id in chunk) {
          _inFlight.remove(id)?.completeError(error, stack);
        }
      }
    }
  }
}
