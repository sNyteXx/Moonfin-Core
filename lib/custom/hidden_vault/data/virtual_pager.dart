import 'dart:collection';

/// Pages a server list as if the hidden items had never been in it.
///
/// Callers keep paging by what they were given (offset = items received so
/// far), which is how every list in the app pages today. This remembers, per
/// query, where each visible offset sits on the server so the next page
/// starts exactly behind the last item handed out: nothing repeated, nothing
/// skipped. When a page comes back short because hidden items were dropped,
/// it reads further ahead within a fixed budget so rows don't run thin.
class VirtualPager {
  /// Extra requests one page may cost on top of the first.
  static const maxExtraRequests = 3;

  /// Largest page asked for while reading ahead.
  static const maxReadAheadPage = 200;

  /// Queries remembered at once; the oldest is forgotten first.
  static const maxSignatures = 64;

  /// Reading ahead stops once a page holds this many items (or its whole
  /// limit, when smaller). A home row shows about fifteen; a caller asking
  /// for sixty to collapse episodes, or a hundred for bookkeeping, doesn't
  /// need every slot refilled, and the next page picks up where this one
  /// stopped either way.
  static const fullPageTarget = 24;

  final LinkedHashMap<String, SplayTreeMap<int, int>> _checkpoints =
      LinkedHashMap();

  /// Requests this pager sent, for tests and the performance log.
  int requestCount = 0;

  int _rawOffsetFor(String signature, int visibleOffset) {
    if (visibleOffset <= 0) return 0;
    final points = _checkpoints[signature];
    if (points == null) return visibleOffset;
    final exact = points[visibleOffset];
    if (exact != null) return exact;
    // A jump the caller never paged up to. Assume nothing hidden past the
    // nearest known point; callers drop repeats, which covers the rest.
    final floor = points.lastKeyBefore(visibleOffset);
    if (floor == null) return visibleOffset;
    return points[floor]! + (visibleOffset - floor);
  }

  void _remember(String signature, int visibleOffset, int rawOffset) {
    final points = _checkpoints.remove(signature) ?? SplayTreeMap<int, int>();
    points[visibleOffset] = rawOffset;
    _checkpoints[signature] = points;
    while (_checkpoints.length > maxSignatures) {
      _checkpoints.remove(_checkpoints.keys.first);
    }
  }

  /// One page of [limit] visible items starting at visible [startIndex].
  ///
  /// [fetch] reads raw server items. [visibleOf] returns the subset that may
  /// be shown, reusing the same map instances. [paged] says whether [fetch]
  /// honours a start index; a list that only takes a limit is read again with
  /// a bigger one instead.
  Future<Map<String, dynamic>> page({
    required String signature,
    required int? startIndex,
    required int? limit,
    required bool paged,
    required Future<Map<String, dynamic>> Function(int? start, int? limit)
    fetch,
    required Future<List<Map<String, dynamic>>> Function(
      List<Map<String, dynamic>> raw,
    )
    visibleOf,
  }) async {
    final visibleStart = startIndex ?? 0;

    if (limit == null || limit <= 0) {
      final rawStart = paged && startIndex != null
          ? _rawOffsetFor(signature, visibleStart)
          : startIndex;
      requestCount++;
      final response = await fetch(rawStart, limit);
      final raw = _items(response);
      final visible = await visibleOf(raw);
      return _withItems(
        response,
        visible,
        removed: raw.length - visible.length,
        visibleStart: startIndex,
      );
    }

    var rawCursor = paged ? _rawOffsetFor(signature, visibleStart) : 0;
    final collected = <Map<String, dynamic>>[];
    final seenIds = <String>{};
    var requestLimit = limit;
    var extraRequests = 0;
    Map<String, dynamic> lastResponse = const {};
    int? rawTotal;
    var exhausted = false;

    while (true) {
      requestCount++;
      final response = await fetch(paged ? rawCursor : null, requestLimit);
      lastResponse = response;
      final raw = _items(response);
      final total = response['TotalRecordCount'];
      if (total is int) rawTotal = total;
      final visible = Set<Map<String, dynamic>>.identity()
        ..addAll(await visibleOf(raw));

      if (!paged) {
        // Read again from the top with a bigger window.
        collected.clear();
        seenIds.clear();
      }
      var consumed = 0;
      for (final item in raw) {
        consumed++;
        if (!visible.contains(item)) continue;
        final id = item['Id']?.toString();
        if (id != null && !seenIds.add(id)) continue;
        collected.add(item);
        if (collected.length >= limit) break;
      }
      if (paged) rawCursor += consumed;

      if (collected.length >= limit) break;
      if (raw.length < requestLimit) {
        exhausted = true;
        break;
      }
      if (paged && rawTotal != null && rawCursor >= rawTotal) {
        exhausted = true;
        break;
      }
      if (extraRequests >= maxExtraRequests) break;
      // Nothing was dropped, so a short page means the end.
      if (visible.length == raw.length) break;
      if (collected.length >=
          (limit < fullPageTarget ? limit : fullPageTarget)) {
        break;
      }
      extraRequests++;
      if (paged) {
        final ceiling = limit > maxReadAheadPage ? limit : maxReadAheadPage;
        final grown = requestLimit * 2;
        requestLimit = grown > ceiling ? ceiling : grown;
      } else {
        final grown = requestLimit * 3;
        if (requestLimit >= maxReadAheadPage) break;
        requestLimit = grown > maxReadAheadPage ? maxReadAheadPage : grown;
      }
    }

    final visibleEnd = visibleStart + collected.length;
    if (paged) _remember(signature, visibleEnd, rawCursor);

    int? adjustedTotal;
    if (rawTotal != null) {
      if (exhausted) {
        adjustedTotal = visibleEnd;
      } else if (paged) {
        // Everything hidden so far is known; assume nothing hidden beyond.
        final hiddenSoFar = rawCursor - visibleEnd;
        adjustedTotal = (rawTotal - hiddenSoFar).clamp(visibleEnd, rawTotal);
      } else {
        adjustedTotal = rawTotal;
      }
    }
    return {
      ...lastResponse,
      'Items': collected,
      'TotalRecordCount': ?adjustedTotal,
      'StartIndex': ?startIndex,
    };
  }

  static List<Map<String, dynamic>> _items(Map<String, dynamic> response) {
    final items = response['Items'];
    if (items is! List) return const [];
    return [
      for (final item in items)
        if (item is Map<String, dynamic>)
          item
        else if (item is Map)
          item.cast<String, dynamic>(),
    ];
  }

  static Map<String, dynamic> _withItems(
    Map<String, dynamic> response,
    List<Map<String, dynamic>> visible, {
    required int removed,
    int? visibleStart,
  }) {
    final total = response['TotalRecordCount'];
    return {
      ...response,
      'Items': visible,
      if (total is int) 'TotalRecordCount': total - removed,
      'StartIndex': ?visibleStart,
    };
  }
}
