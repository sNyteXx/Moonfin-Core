import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';

import '../../custom/hidden_vault/hidden_vault.dart';
import '../database/offline_database.dart';
import '../repositories/offline_repository.dart';

OfflineRepository get _repo => GetIt.instance<OfflineRepository>();

// hidden-vault: saved copies of hidden content stay on disk but off the lists.
List<DownloadedItem> _visible(List<DownloadedItem> rows) =>
    HiddenVault.withoutHiddenDownloads(rows);

/// Item types that are an actual file on disk.
const downloadableItemTypes = <String>{
  'Movie',
  'Episode',
  'Audio',
  'AudioBook',
  'Book',
  'MusicVideo',
  'Video',
};

/// What the saved media list needs from one read of the table.
class DownloadCatalog {
  const DownloadCatalog({required this.items, required this.containerArtwork});

  /// Completed downloads that are a real file on disk.
  final List<DownloadedItem> items;

  /// Posters of the Series, Season and MusicAlbum rows the files hang under,
  /// keyed by item id, so a show's row can show the show's own artwork.
  final Map<String, String> containerArtwork;

  static const empty = DownloadCatalog(items: [], containerArtwork: {});
}

/// Splits a read of the downloads table into the files worth listing and the
/// artwork of the containers they hang under.
///
/// Saving an episode also writes a Series and a Season row so the offline
/// catalog can browse to them. Those rows count as complete and carry artwork
/// but no file, so listing them unfiltered puts empty rows in front of people.
DownloadCatalog partitionDownloadCatalog(List<DownloadedItem> rows) {
  final items = <DownloadedItem>[];
  final artwork = <String, String>{};
  for (final row in rows) {
    if (row.fileSizeBytes > 0 && downloadableItemTypes.contains(row.type)) {
      items.add(row);
    } else if (row.posterPath?.isNotEmpty ?? false) {
      artwork[row.itemId] = row.posterPath!;
    }
  }
  return DownloadCatalog(items: items, containerArtwork: artwork);
}

/// Watching the table rather than reading it once is what lets the list drop a
/// row the moment a delete lands.
final downloadedCatalogProvider = StreamProvider<DownloadCatalog>((ref) {
  return _repo
      .watchItems(onlyCompleted: true)
      .map((rows) => partitionDownloadCatalog(_visible(rows)));
});

final downloadedMoviesProvider = StreamProvider<List<DownloadedItem>>((ref) {
  return _repo.watchItems(type: 'Movie', onlyCompleted: true).map(_visible);
});

final downloadedSeriesProvider = StreamProvider<List<DownloadedItem>>((ref) {
  return _repo.watchDownloadedSeries().map(_visible);
});

final downloadedAudioProvider = StreamProvider<List<DownloadedItem>>((ref) {
  return _repo.watchItems(type: 'Audio', onlyCompleted: true).map(_visible);
});

final downloadedAudioBooksProvider = StreamProvider<List<DownloadedItem>>((ref) {
  return _repo
      .watchItems(type: 'AudioBook', onlyCompleted: true)
      .map(_visible);
});

final downloadedBooksProvider = StreamProvider<List<DownloadedItem>>((ref) {
  return _repo.watchItems(type: 'Book', onlyCompleted: true).map(_visible);
});

final downloadedEpisodesProvider =
    StreamProvider.family<List<DownloadedItem>, String>((ref, seriesId) {
  return _repo.watchSeriesEpisodes(seriesId).map(_visible);
});

final downloadedSeasonEpisodesProvider =
    StreamProvider.family<List<DownloadedItem>, String>((ref, seasonId) {
  return _repo.watchSeasonEpisodes(seasonId).map(_visible);
});

final storageUsedProvider = StreamProvider<int>((ref) {
  return _repo.watchTotalStorageUsed();
});

final downloadedItemProvider =
    StreamProvider.family<DownloadedItem?, String>((ref, itemId) {
  return _repo.watchItem(itemId);
});
