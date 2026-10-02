import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:server_core/server_core.dart';

import '../model/hidden_tag_policy.dart';
import '../model/tag_match.dart';
import '../model/vault_config.dart';
import 'hidden_content_index.dart';
import 'item_tag_resolver.dart';
import 'vault_store.dart';

enum VerdictKind { visible, hidden, unknown }

/// What the rules say about one server item.
class ItemVerdict {
  final VerdictKind kind;

  /// The vault the item belongs to, when it is hidden and the index knows
  /// where it sits. Null for a hidden item whose library isn't confirmed yet.
  final String? vaultId;

  /// For [VerdictKind.hidden]: the tags match a rule but the index hasn't
  /// placed the item in a covered library yet. Held back until it has.
  final String? suspectId;

  /// For [VerdictKind.unknown]: whose tags still have to be read.
  final String? resolveId;

  const ItemVerdict._(this.kind, {this.vaultId, this.suspectId, this.resolveId});

  static const visible = ItemVerdict._(VerdictKind.visible);

  const ItemVerdict.hidden(String? vaultId)
    : this._(VerdictKind.hidden, vaultId: vaultId);

  const ItemVerdict.suspect(String id)
    : this._(VerdictKind.hidden, suspectId: id);

  const ItemVerdict.unknown(String id)
    : this._(VerdictKind.unknown, resolveId: id);

  bool get isHidden => kind == VerdictKind.hidden;
  bool get isSuspect => suspectId != null;

  @override
  String toString() =>
      'ItemVerdict($kind, vault=$vaultId, suspect=$suspectId, resolve=$resolveId)';
}

/// Decides whether a hidden item may still be shown in one particular call,
/// given the vault it belongs to. Only item specific calls inside an entered
/// vault ever say yes.
typedef VaultAllowance = bool Function(Map<dynamic, dynamic> raw, String vaultId);

class _TagCheck {
  final bool matches;
  final int checkedAtMs;

  const _TagCheck(this.matches, this.checkedAtMs);
}

/// The hidden content rules of one user on one server, and every answer
/// derived from them.
///
/// Owns the config, the hidden index and the cache of tag lookups. All checks
/// are synchronous map lookups; the only network it ever does is the index
/// build (one request per configured library) and batched tag lookups for
/// series and items it has never seen.
class HiddenContentService extends ChangeNotifier {
  /// How old the index may get before it's rebuilt in the background.
  static const staleAfter = Duration(minutes: 10);

  /// How long a "these tags don't match" answer is trusted. The index catches
  /// a series tagged in the meantime on its next rebuild either way.
  static const checkTtl = Duration(hours: 12);

  static const _resolveTimeout = Duration(seconds: 4);
  static const _suspectRefreshTimeout = Duration(seconds: 6);
  static const _maxStoredChecks = 20000;

  /// Containers sit in no library, so their own tags are the whole answer.
  static const _containerTypes = {'BoxSet', 'Playlist'};

  /// Types worth a tag lookup when a response carried no tag field.
  static const _taggableTypes = {
    'Series',
    'Movie',
    'Video',
    'MusicVideo',
    'BoxSet',
    'Playlist',
  };

  final VaultScope scope;
  final VaultKeyValueStore _store;
  final DateTime Function() _now;
  ItemsApi Function() _onlineApi;
  late final ItemTagResolver _resolver = ItemTagResolver.forApi(
    () => _onlineApi(),
  );

  VaultConfig _config = VaultConfig.empty;
  HiddenTagPolicy _policy = HiddenTagPolicy.none;
  HiddenContentIndex? _index;
  final Map<String, _TagCheck> _checks = {};
  final Set<String> _outOfScope = {};
  final Map<String, DateTime> _suspects = {};
  int _generation = 0;

  Future<void>? _refreshing;
  DateTime? _refreshStartedAt;
  Timer? _persistChecksTimer;
  Timer? _delayedRefresh;

  /// Ids that joined the hidden set on the last index change. The UI uses it
  /// to know whether rows on screen may now show something they shouldn't.
  Set<String> lastAddedIds = const {};

  /// Counters for tests and the performance log.
  int indexBuilds = 0;
  int indexRequests = 0;

  HiddenContentService({
    required this.scope,
    required this._store,
    required this._onlineApi,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _loadPersisted();
  }

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------

  VaultConfig get config => _config;
  HiddenTagPolicy get policy => _policy;
  HiddenContentIndex? get index => _index;
  bool get isActive => _policy.isActive;

  /// Changes whenever the config or the index does.
  int get generation => _generation;

  /// The current rules' fingerprint, for cache keys.
  String get fingerprint => _policy.fingerprint;

  /// How many tag lookup requests went out.
  int get resolverRequests => _resolver.requestCount;

  set onlineApi(ItemsApi Function() api) => _onlineApi = api;

  bool isRuleLibrary(String? id) => id != null && _policy.ruleFor(id) != null;

  void _loadPersisted() {
    _config = VaultConfig.decode(_store.getString(VaultStorageKeys.config(scope)));
    _policy = HiddenTagPolicy.fromConfig(_config);
    if (!_policy.isActive) return;
    final index = HiddenContentIndex.decode(
      _store.getString(VaultStorageKeys.index(scope)),
    );
    if (index != null && index.fingerprint == _policy.fingerprint) {
      _index = index;
    }
    _loadChecks();
  }

  void _loadChecks() {
    final source = _store.getString(VaultStorageKeys.checks(scope));
    if (source == null || source.isEmpty) return;
    try {
      final json = jsonDecode(source);
      if (json is! Map || json['fp'] != _policy.fingerprint) return;
      final checks = json['c'];
      if (checks is Map) {
        checks.forEach((id, value) {
          if (value is List && value.length == 2) {
            _checks[id.toString()] = _TagCheck(
              value[0] == 1,
              (value[1] as num).toInt() * 1000,
            );
          }
        });
      }
      final out = json['o'];
      if (out is List) _outOfScope.addAll(out.map((e) => e.toString()));
    } catch (_) {}
  }

  void _persistChecksSoon() {
    _persistChecksTimer?.cancel();
    _persistChecksTimer = Timer(const Duration(seconds: 2), _persistChecks);
  }

  Future<void> _persistChecks() async {
    _persistChecksTimer = null;
    if (_checks.length > _maxStoredChecks) {
      final sorted = _checks.entries.toList()
        ..sort((a, b) => a.value.checkedAtMs.compareTo(b.value.checkedAtMs));
      for (final entry in sorted.take(_checks.length - _maxStoredChecks)) {
        _checks.remove(entry.key);
      }
    }
    final json = {
      'fp': _policy.fingerprint,
      'c': {
        for (final e in _checks.entries)
          e.key: [e.value.matches ? 1 : 0, e.value.checkedAtMs ~/ 1000],
      },
      'o': _outOfScope.toList(),
    };
    try {
      await _store.setString(VaultStorageKeys.checks(scope), jsonEncode(json));
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Config
  // ---------------------------------------------------------------------------

  /// Stores [next] and, when what is hidden changed, rebuilds the index before
  /// returning so nothing renders against the old rules.
  Future<void> saveConfig(VaultConfig next) async {
    final saved = next.copyWith(revision: _config.revision + 1);
    final rulesChanged = saved.fingerprint != _config.fingerprint;
    _config = saved;
    await _store.setString(VaultStorageKeys.config(scope), saved.encode());
    if (rulesChanged) {
      _policy = HiddenTagPolicy.fromConfig(saved);
      _index = null;
      _checks.clear();
      _outOfScope.clear();
      _suspects.clear();
      await _store.remove(VaultStorageKeys.index(scope));
      await _store.remove(VaultStorageKeys.checks(scope));
      _generation++;
      notifyListeners();
      if (_policy.isActive) await refreshIndex();
    } else {
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------------
  // Index lifecycle
  // ---------------------------------------------------------------------------

  /// Makes sure there is an index to answer from. A stored one is used at once
  /// and refreshed in the background when old; only the very first build is
  /// waited for. If even that fails, answers fall back to the tags alone,
  /// which hides too much rather than too little.
  Future<void> ensureReady() async {
    if (!isActive) return;
    final index = _index;
    if (index != null) {
      if (index.isStale(_now(), staleAfter) && _refreshing == null) {
        unawaited(refreshIndex().catchError((_) {}));
      }
      return;
    }
    try {
      await refreshIndex();
    } catch (error) {
      debugPrint('[HiddenVault] index build failed, tag-only fallback: $error');
    }
  }

  /// Rebuilds the index. Concurrent callers share one build.
  Future<void> refreshIndex() {
    final running = _refreshing;
    if (running != null) return running;
    final future = _rebuild();
    _refreshing = future;
    return future.whenComplete(() {
      if (identical(_refreshing, future)) _refreshing = null;
    });
  }

  Future<void> _rebuild() async {
    final policy = _policy;
    if (!policy.isActive) return;
    final startedAt = _now();
    _refreshStartedAt = startedAt;
    final stats = HiddenIndexBuildStats();
    final built = await HiddenIndexBuilder(
      _onlineApi(),
    ).build(policy, now: startedAt, stats: stats);
    indexBuilds++;
    indexRequests += stats.requests;
    debugPrint('[HiddenVault] index built: ${built.length} hidden, $stats');
    // The rules changed while this ran; that save starts a build of its own.
    if (policy.fingerprint != _policy.fingerprint) return;

    final previous = _index;
    final added = <String>{
      for (final id in built.ids)
        if (previous == null || !previous.contains(id)) id,
    };
    _index = built;
    lastAddedIds = added;

    // A suspect seen before this build started has been looked for by it. If
    // the build didn't place it, it sits outside every covered library.
    final settled = <String>[];
    _suspects.forEach((id, firstSeen) {
      if (!firstSeen.isAfter(startedAt)) settled.add(id);
    });
    for (final id in settled) {
      _suspects.remove(id);
      if (!built.contains(id)) _outOfScope.add(id);
    }
    // Something that left the hidden set may come back into scope later, so
    // the out-of-scope memory never overrides the index; nothing to prune.
    _generation++;
    try {
      await _store.setString(VaultStorageKeys.index(scope), built.encode());
    } catch (_) {}
    // Written now rather than debounced: what a rebuild settled is what saves
    // the next start from repeating it.
    _persistChecksTimer?.cancel();
    await _persistChecks();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Verdicts
  // ---------------------------------------------------------------------------

  _TagCheck? _check(String id) {
    final check = _checks[id];
    if (check == null) return null;
    final age = _now().millisecondsSinceEpoch - check.checkedAtMs;
    if (age > checkTtl.inMilliseconds) return null;
    return check;
  }

  void _recordCheck(String id, List<String> tags) {
    _checks[id] = _TagCheck(
      _policy.matchesAnyRule(tags),
      _now().millisecondsSinceEpoch,
    );
  }

  static String? _str(Object? value) {
    final text = value?.toString();
    return text == null || text.isEmpty ? null : text;
  }

  /// The answer from what is in hand, without any network.
  ItemVerdict verdictOf(Map<dynamic, dynamic> raw) {
    if (!isActive) return ItemVerdict.visible;
    final id = _str(raw['Id']);
    final type = _str(raw['Type']);
    final seriesId = _str(raw['SeriesId']);
    final seasonId = _str(raw['SeasonId']);

    final index = _index;
    if (index != null) {
      final entry = index[id] ?? index[seriesId] ?? index[seasonId];
      if (entry != null) return ItemVerdict.hidden(entry.vaultId);
    }

    final tags = extractTags(raw);
    if (tags != null && _policy.matchesAnyRule(tags)) {
      if (_containerTypes.contains(type)) return const ItemVerdict.hidden(null);
      if (index == null) return const ItemVerdict.hidden(null);
      if (id != null && !_outOfScope.contains(id)) {
        return ItemVerdict.suspect(id);
      }
    }

    final parent = seriesId ?? seasonId;
    if (parent != null && parent != id) {
      final check = _check(parent);
      if (check == null) return ItemVerdict.unknown(parent);
      if (check.matches) {
        if (index == null) return const ItemVerdict.hidden(null);
        if (!_outOfScope.contains(parent)) return ItemVerdict.suspect(parent);
      }
    }

    if (tags == null && id != null && _taggableTypes.contains(type)) {
      final check = _check(id);
      if (check == null) return ItemVerdict.unknown(id);
      if (check.matches) {
        if (_containerTypes.contains(type) || index == null) {
          return const ItemVerdict.hidden(null);
        }
        if (!_outOfScope.contains(id)) return ItemVerdict.suspect(id);
      }
    }
    return ItemVerdict.visible;
  }

  /// Whether the item is hidden in the normal context according to what is in
  /// hand. Unknowns read as visible here; [settle] is the authoritative path.
  bool isHiddenNow(Map<dynamic, dynamic> raw) => verdictOf(raw).isHidden;

  /// Records the tags of every item that came with them, so a series listed
  /// next to its own episodes never needs a lookup.
  void _learn(List<Map<dynamic, dynamic>> raws) {
    var learned = false;
    for (final raw in raws) {
      final id = _str(raw['Id']);
      if (id == null) continue;
      final tags = extractTags(raw);
      if (tags == null) continue;
      if (!_taggableTypes.contains(_str(raw['Type']))) continue;
      _recordCheck(id, tags);
      learned = true;
    }
    if (learned) _persistChecksSoon();
  }

  /// The final verdict for each of [raws]: unknown series and items are
  /// looked up in one batch, and suspects wait for an index rebuild that can
  /// place them.
  Future<List<ItemVerdict>> settle(List<Map<dynamic, dynamic>> raws) async {
    if (!isActive || raws.isEmpty) {
      return List.filled(raws.length, ItemVerdict.visible);
    }
    _learn(raws);
    var verdicts = [for (final raw in raws) verdictOf(raw)];

    final unknown = {
      for (final v in verdicts)
        if (v.kind == VerdictKind.unknown) v.resolveId!,
    };
    final failed = <String>{};
    if (unknown.isNotEmpty) {
      try {
        final tags = await _resolver.resolve(unknown).timeout(_resolveTimeout);
        for (final id in unknown) {
          _recordCheck(id, tags[id] ?? const []);
        }
        _persistChecksSoon();
      } catch (error) {
        // The list request that brought these in just worked, so this is
        // rare. The index still answers for everything it knows.
        debugPrint('[HiddenVault] tag lookup failed: $error');
        failed.addAll(unknown);
      }
      verdicts = [
        for (var i = 0; i < raws.length; i++)
          verdicts[i].kind == VerdictKind.unknown
              ? (failed.contains(verdicts[i].resolveId)
                    ? ItemVerdict.visible
                    : verdictOf(raws[i]))
              : verdicts[i],
      ];
    }

    final suspects = {
      for (final v in verdicts)
        if (v.isSuspect) v.suspectId!,
    };
    if (suspects.isNotEmpty) {
      await _placeSuspects(suspects);
      verdicts = [
        for (var i = 0; i < raws.length; i++)
          verdicts[i].isSuspect ? verdictOf(raws[i]) : verdicts[i],
      ];
    }
    return [
      for (final v in verdicts)
        v.kind == VerdictKind.unknown ? ItemVerdict.visible : v,
    ];
  }

  /// Rebuilds the index so it can say whether [ids] sit in a covered library.
  /// Until it has, they stay hidden.
  Future<void> _placeSuspects(Set<String> ids) async {
    final now = _now();
    for (final id in ids) {
      _suspects.putIfAbsent(id, () => now);
    }
    try {
      final running = _refreshing;
      final startedAt = _refreshStartedAt;
      if (running != null && startedAt != null) {
        await running.timeout(_suspectRefreshTimeout);
        // That build may have started before these were seen; one more
        // settles them for good.
        if (ids.any((id) => _suspects.containsKey(id))) {
          await refreshIndex().timeout(_suspectRefreshTimeout);
        }
      } else {
        await refreshIndex().timeout(_suspectRefreshTimeout);
      }
    } catch (error) {
      debugPrint('[HiddenVault] could not place suspects yet: $error');
      _delayedRefresh ??= Timer(const Duration(seconds: 20), () {
        _delayedRefresh = null;
        unawaited(refreshIndex().catchError((_) {}));
      });
    }
  }

  /// [raws] without what the normal context may not see. [allow] lets an item
  /// specific call inside an entered vault keep that vault's items.
  Future<List<T>> visible<T extends Map<dynamic, dynamic>>(
    List<T> raws, {
    VaultAllowance? allow,
  }) async {
    if (!isActive || raws.isEmpty) return raws;
    final verdicts = await settle(raws);
    final result = <T>[];
    for (var i = 0; i < raws.length; i++) {
      final verdict = verdicts[i];
      if (!verdict.isHidden) {
        result.add(raws[i]);
        continue;
      }
      final vaultId = verdict.vaultId;
      if (vaultId != null && allow != null && allow(raws[i], vaultId)) {
        result.add(raws[i]);
      }
    }
    return result;
  }

  /// The settled verdict for one item, for the detail and playback gates.
  Future<ItemVerdict> settledVerdict(Map<dynamic, dynamic> raw) async {
    if (!isActive) return ItemVerdict.visible;
    await ensureReady();
    return (await settle([raw])).single;
  }

  /// Whether [raw] belongs to [vaultId] for the vault's own screens: in its
  /// index, or an episode or season of something that is.
  bool belongsToVault(Map<dynamic, dynamic> raw, String vaultId) {
    final index = _index;
    if (index == null) return false;
    final entry =
        index[_str(raw['Id'])] ??
        index[_str(raw['SeriesId'])] ??
        index[_str(raw['SeasonId'])];
    return entry?.vaultId == vaultId;
  }

  @override
  void dispose() {
    _persistChecksTimer?.cancel();
    _delayedRefresh?.cancel();
    super.dispose();
  }
}
