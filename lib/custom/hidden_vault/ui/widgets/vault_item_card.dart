import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:server_core/server_core.dart';

import '../../../../data/models/aggregated_item.dart';
import '../../../../ui/navigation/destinations.dart';
import '../../../../ui/widgets/focus/context_menu_sheet.dart';
import '../../../../ui/widgets/media_card.dart';
import 'vault_card_metrics.dart';

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
      return images.getPrimaryImageUrl(
        item.id,
        maxWidth: maxWidth,
        tag: primary,
      );
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
    final code = (season is int && episode is int)
        ? 'S$season:E$episode'
        : null;
    return [?code, ?series].join(' · ');
  }
  final year = raw['ProductionYear'];
  return year?.toString();
}

/// Opens [item] in the regular detail screen. That screen is allowed to show
/// it only because the vault is open; the decision is made by the vault
/// session, not by anything in this route.
void openVaultItem(BuildContext context, AggregatedItem item) {
  GoRouter.of(context)
      .push(Destinations.item(item.id, serverId: item.serverId));
}

/// One vault title, drawn with the home screen's [MediaCard] at the home
/// screen's sizes. A long press (or the menu key) opens the same context
/// menu as on the home screen.
class VaultItemCard extends StatelessWidget {
  final AggregatedItem item;
  final ImageApi images;
  final VaultCardMetrics metrics;
  final bool autofocus;
  final FocusNode? focusNode;

  /// Set when a [LockedFocusRow] owns the focus; the card then draws focus
  /// from this and takes no keys of its own.
  final bool? externalIsFocused;
  final VoidCallback? onChanged;

  const VaultItemCard({
    super.key,
    required this.item,
    required this.images,
    required this.metrics,
    this.autofocus = false,
    this.focusNode,
    this.externalIsFocused,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final userData = item.rawData['UserData'] as Map?;
    final played = userData?['PlayedPercentage'];
    final unplayed = userData?['UnplayedItemCount'];
    return MediaCard(
      title: item.name,
      subtitle: vaultSubtitle(item),
      imageUrl: vaultImageUrl(
        images,
        item,
        landscape: metrics.landscape,
        maxWidth: (metrics.width * 2).round(),
      ),
      width: metrics.width,
      aspectRatio: metrics.aspectRatio,
      itemType: item.type,
      isPlayed: userData?['Played'] == true,
      isFavorite: userData?['IsFavorite'] == true,
      unplayedCount: unplayed is int && unplayed > 0 ? unplayed : null,
      playedPercentage: played is num ? played.toDouble() : null,
      watchedBehavior: metrics.watchedBehavior,
      cardFocusExpansion: metrics.expansion,
      externalIsFocused: externalIsFocused,
      autofocus: autofocus,
      focusNode: focusNode,
      onTap: () => openVaultItem(context, item),
      onLongPress: () => showVaultItemMenu(context, item, onChanged: onChanged),
    );
  }
}

/// The home screen's context menu for a vault title.
void showVaultItemMenu(
  BuildContext context,
  AggregatedItem item, {
  VoidCallback? onChanged,
}) => unawaited(showContextMenu(context, item, onChanged: onChanged));

/// A grid of vault posters sized like the home screen's rows, with room
/// above every row for a focused card to grow.
class VaultCardGrid extends StatelessWidget {
  static const sidePadding = 48.0;

  final List<AggregatedItem> items;
  final ImageApi images;

  /// Called with each index as it is built, for paging.
  final void Function(int index)? onBuildIndex;
  final VoidCallback? onChanged;

  const VaultCardGrid({
    super.key,
    required this.items,
    required this.images,
    this.onBuildIndex,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final metrics = VaultCardMetrics.of(landscape: false);
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth - sidePadding * 2;
        final columns = math.max(
          1,
          ((available + metrics.spacing) / (metrics.width + metrics.spacing))
              .floor(),
        );
        return FocusTraversalGroup(
          child: GridView.builder(
            padding: EdgeInsets.fromLTRB(
              sidePadding,
              metrics.headroom + 8,
              sidePadding,
              48,
            ),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: metrics.spacing,
              mainAxisSpacing: metrics.headroom + 12,
              mainAxisExtent: metrics.cardHeight,
            ),
            itemCount: items.length,
            itemBuilder: (context, index) {
              onBuildIndex?.call(index);
              return Align(
                alignment: Alignment.topCenter,
                child: VaultItemCard(
                  item: items[index],
                  images: images,
                  metrics: metrics,
                  autofocus: index == 0,
                  onChanged: onChanged,
                ),
              );
            },
          ),
        );
      },
    );
  }
}
