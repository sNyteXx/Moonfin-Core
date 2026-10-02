import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:server_core/server_core.dart';

import '../../../../data/models/aggregated_item.dart';
import '../../../../ui/navigation/destinations.dart';
import '../../../../ui/widgets/media_card.dart';

/// Artwork for a vault card. Episodes show a landscape still, everything else
/// its poster.
String? vaultImageUrl(
  ImageApi images,
  AggregatedItem item, {
  required bool landscape,
  int maxWidth = 400,
}) {
  final raw = item.rawData;
  if (landscape) {
    final thumb = (raw['ImageTags'] as Map?)?['Thumb'] as String?;
    if (thumb != null) {
      return images.getThumbImageUrl(item.id, maxWidth: maxWidth, tag: thumb);
    }
    final primary = item.primaryImageTag;
    if (item.type == 'Episode' && primary != null) {
      return images.getPrimaryImageUrl(item.id, maxWidth: maxWidth, tag: primary);
    }
    final parentThumbId = raw['ParentThumbItemId']?.toString();
    final parentThumb = raw['ParentThumbImageTag'] as String?;
    if (parentThumbId != null && parentThumb != null) {
      return images.getThumbImageUrl(
        parentThumbId,
        maxWidth: maxWidth,
        tag: parentThumb,
      );
    }
    final backdrops = item.backdropImageTags;
    if (backdrops.isNotEmpty) {
      return images.getBackdropImageUrl(
        item.id,
        maxWidth: maxWidth,
        tag: backdrops.first,
      );
    }
  }
  final primary = item.primaryImageTag;
  if (primary != null) {
    return images.getPrimaryImageUrl(item.id, maxWidth: maxWidth, tag: primary);
  }
  final seriesId = item.seriesId;
  final seriesPrimary = raw['SeriesPrimaryImageTag'] as String?;
  if (seriesId != null && seriesPrimary != null) {
    return images.getPrimaryImageUrl(
      seriesId,
      maxWidth: maxWidth,
      tag: seriesPrimary,
    );
  }
  return null;
}

String? vaultSubtitle(AggregatedItem item) {
  final raw = item.rawData;
  if (item.type == 'Episode') {
    final season = raw['ParentIndexNumber'];
    final episode = raw['IndexNumber'];
    final series = raw['SeriesName']?.toString();
    final code = (season is int && episode is int) ? 'S$season:E$episode' : null;
    return [?code, ?series].join(' · ');
  }
  final year = raw['ProductionYear'];
  return year?.toString();
}

/// Opens [item] in the regular detail screen. That screen is allowed to show
/// it only because the vault is open; the decision is made by the vault
/// session, not by anything in this route.
void openVaultItem(BuildContext context, AggregatedItem item) {
  GoRouter.of(context).push(Destinations.item(item.id, serverId: item.serverId));
}

class VaultItemCard extends StatelessWidget {
  final AggregatedItem item;
  final ImageApi images;
  final bool landscape;
  final double width;
  final bool autofocus;
  final FocusNode? focusNode;

  const VaultItemCard({
    super.key,
    required this.item,
    required this.images,
    this.landscape = false,
    this.width = 150,
    this.autofocus = false,
    this.focusNode,
  });

  @override
  Widget build(BuildContext context) {
    final userData = item.rawData['UserData'] as Map?;
    final played = userData?['PlayedPercentage'];
    return MediaCard(
      title: item.name,
      subtitle: vaultSubtitle(item),
      imageUrl: vaultImageUrl(
        images,
        item,
        landscape: landscape,
        maxWidth: (width * 2).round(),
      ),
      width: width,
      aspectRatio: landscape ? 16 / 9 : 2 / 3,
      itemType: item.type,
      isPlayed: userData?['Played'] == true,
      isFavorite: userData?['IsFavorite'] == true,
      playedPercentage: played is num ? played.toDouble() : null,
      autofocus: autofocus,
      focusNode: focusNode,
      onTap: () => openVaultItem(context, item),
    );
  }
}
