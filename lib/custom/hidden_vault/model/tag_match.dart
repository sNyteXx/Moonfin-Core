/// Tag handling for the hidden content vault.
///
/// Matching is exact on the whole tag and ignores case, so `Ecchi` matches
/// `ecchi` while `adult` never matches `adult animation` and `hidden` never
/// matches `hidden gem`. Normalized values are only ever used for comparing;
/// anything shown on screen keeps the server's spelling.
library;

final _whitespaceRun = RegExp(r'\s+');

/// The comparison form of [tag]: trimmed, inner whitespace collapsed to one
/// space, lower cased. Empty when nothing is left.
String normalizeTag(String tag) =>
    tag.trim().replaceAll(_whitespaceRun, ' ').toLowerCase();

/// The normalized, de-duplicated, non-empty form of [tags].
Set<String> normalizeTags(Iterable<String> tags) {
  final result = <String>{};
  for (final tag in tags) {
    final normalized = normalizeTag(tag);
    if (normalized.isNotEmpty) result.add(normalized);
  }
  return result;
}

/// The tags a raw server item carries, as the server spelled them, or null
/// when the response held no tag field at all.
///
/// Null and empty mean different things: an item fetched without the field
/// says nothing about its tags, while an empty list says it has none.
///
/// Jellyfin answers `Tags: ["a", "b"]`. Emby can answer `TagItems:
/// [{"Name": "a", "Id": 1}]` instead, so both are read.
List<String>? extractTags(Map<dynamic, dynamic> raw) {
  final tags = raw['Tags'];
  final tagItems = raw['TagItems'];
  if (tags == null && tagItems == null) return null;
  final result = <String>[];
  if (tags is List) {
    for (final tag in tags) {
      if (tag is String) {
        result.add(tag);
      } else if (tag is Map && tag['Name'] is String) {
        result.add(tag['Name'] as String);
      } else if (tag != null) {
        result.add(tag.toString());
      }
    }
  } else if (tags is String && tags.isNotEmpty) {
    result.add(tags);
  }
  if (tagItems is List) {
    for (final tag in tagItems) {
      if (tag is Map && tag['Name'] != null) {
        result.add(tag['Name'].toString());
      } else if (tag is String) {
        result.add(tag);
      }
    }
  }
  return result;
}

/// Whether any of [itemTags] equals one of [hiddenTags] exactly, ignoring
/// case. [hiddenTags] must already be normalized.
bool matchesAnyTag(Iterable<String> itemTags, Set<String> hiddenTags) {
  if (hiddenTags.isEmpty) return false;
  for (final tag in itemTags) {
    if (hiddenTags.contains(normalizeTag(tag))) return true;
  }
  return false;
}
