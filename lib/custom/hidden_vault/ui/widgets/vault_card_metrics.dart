import 'package:get_it/get_it.dart';

import '../../../../preference/preference_constants.dart';
import '../../../../preference/user_preferences.dart';
import '../../../../ui/widgets/media_card.dart';
import '../../../../util/platform_detection.dart';

/// Card sizes for vault rows and grids, worked out the way the home screen
/// does: from the user's poster size, UI scale and focus expansion.
///
/// A focused card grows upward from the bottom of its artwork, so rows and
/// grids keep [headroom] free above the cards; without it the grown card is
/// cut off at the top.
class VaultCardMetrics {
  /// Title, subtitle and the gaps under the artwork.
  static const metadataHeight = 60.0;

  final bool landscape;
  final double imageHeight;
  final double width;
  final double headroom;
  final double spacing;
  final bool expansion;
  final WatchedIndicatorBehavior watchedBehavior;

  const VaultCardMetrics._({
    required this.landscape,
    required this.imageHeight,
    required this.width,
    required this.headroom,
    required this.spacing,
    required this.expansion,
    required this.watchedBehavior,
  });

  factory VaultCardMetrics.of({required bool landscape}) {
    final getIt = GetIt.instance;
    final prefs = getIt.isRegistered<UserPreferences>()
        ? getIt<UserPreferences>()
        : null;
    final poster = prefs?.get(UserPreferences.posterSize) ?? PosterSize.medium;
    final uiScale =
        prefs?.get(UserPreferences.desktopUiScale).scaleFactor ?? 1.0;
    final scale = PlatformDetection.isTV ? 0.8 * uiScale : uiScale;
    final imageHeight =
        (landscape ? poster.landscapeHeight : poster.portraitHeight) * scale;
    final width = imageHeight * (landscape ? 16 / 9 : 2 / 3);
    final expansion =
        (prefs?.get(UserPreferences.cardFocusExpansion) ?? true) &&
        !PlatformDetection.useMobileUi;
    return VaultCardMetrics._(
      landscape: landscape,
      imageHeight: imageHeight,
      width: width,
      headroom: expansion ? imageHeight * (MediaCard.focusScale - 1) : 0,
      spacing: expansion ? MediaCard.focusGap(width) : 12,
      expansion: expansion,
      watchedBehavior:
          prefs?.get(UserPreferences.watchedIndicatorBehavior) ??
          WatchedIndicatorBehavior.always,
    );
  }

  double get aspectRatio => landscape ? 16 / 9 : 2 / 3;

  /// One card, artwork and text.
  double get cardHeight => imageHeight + metadataHeight;

  /// One row of cards including the room a focused card grows into.
  double get rowHeight => headroom + cardHeight;
}
