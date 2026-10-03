import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:moonfin_design/moonfin_design.dart';

import '../../../data/models/aggregated_item.dart';
import '../../../ui/widgets/focus/locked_focus_row.dart';
import '../../../ui/widgets/fullscreen_backdrop_switcher.dart';
import '../../../ui/widgets/grid_button_card.dart';
import '../../../ui/widgets/info_area.dart';
import '../model/vault_config.dart';
import '../session/vault_session.dart';
import 'vault_routes.dart';
import 'vault_screen_scope.dart';
import 'vault_strings.dart';
import 'widgets/vault_card_metrics.dart';
import 'widgets/vault_item_card.dart';

/// A vault's home, laid out like the app's home screen: the focused title's
/// backdrop behind everything, its details in the info area on top, and rows
/// of the same cards below, all limited to this vault's hidden content.
///
/// The backdrop is this screen's own, not the app's background service, so
/// nothing of the vault stays behind once the screen is gone.
class VaultHomeScreen extends StatelessWidget {
  final String vaultId;

  const VaultHomeScreen({super.key, required this.vaultId});

  @override
  Widget build(BuildContext context) => VaultScreenScope(
    vaultId: vaultId,
    builder: (context, vault) => _VaultHome(vault: vault),
  );
}

class _RowSpec {
  final String title;
  final Future<List<AggregatedItem>> Function() load;
  final bool landscape;
  final VaultLibrary? library;

  _RowSpec(this.title, this.load, {this.landscape = false, this.library});
}

/// The "see all" card at the end of a library row.
const _seeAllPrefix = '__vault_see_all__:';

class _VaultHome extends StatefulWidget {
  final VaultContext vault;

  const _VaultHome({required this.vault});

  @override
  State<_VaultHome> createState() => _VaultHomeState();
}

class _VaultHomeState extends State<_VaultHome> {
  static const _sidePadding = 48.0;

  late List<_RowSpec> _specs;
  final List<List<AggregatedItem>?> _rows = [];
  final List<FocusNode> _rowNodes = [];
  final List<GlobalKey> _rowKeys = [];
  final FocusNode _searchNode = FocusNode(debugLabel: 'vault-search');
  final ScrollController _scroll = ScrollController();

  AggregatedItem? _focused;
  Timer? _focusSettle;
  bool _focusClaimed = false;
  int _generation = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_rows.isEmpty) _load();
  }

  /// Reads every row. On a reload the old rows stay up until their new
  /// content arrives, so the screen doesn't blink and focus stays put.
  void _load({bool keepRows = false}) {
    final s = VaultStrings.of(context);
    final repo = widget.vault.repository;
    _specs = [
      _RowSpec(s.continueWatching, repo.continueWatching, landscape: true),
      _RowSpec(s.nextUp, repo.nextUp, landscape: true),
      _RowSpec(s.recentlyAdded, repo.recentlyAdded),
      for (final library in repo.libraries)
        _RowSpec(
          library.name,
          () => repo.libraryRow(library),
          library: library,
        ),
    ];
    final generation = ++_generation;
    if (!keepRows || _rows.length != _specs.length) {
      _rows
        ..clear()
        ..addAll(List.filled(_specs.length, null));
    }
    while (_rowNodes.length < _specs.length) {
      _rowNodes.add(FocusNode(debugLabel: 'vault-row-${_rowNodes.length}'));
      _rowKeys.add(GlobalKey());
    }
    for (var i = 0; i < _specs.length; i++) {
      unawaited(
        _specs[i].load().then(
          (items) => _rowLoaded(generation, i, items),
          onError: (Object _) => _rowLoaded(generation, i, const []),
        ),
      );
    }
  }

  void _rowLoaded(int generation, int index, List<AggregatedItem> items) {
    if (!mounted || generation != _generation) return;
    final hadFocus = _rowNodes[index].hasFocus;
    setState(() => _rows[index] = items);
    if (hadFocus && items.isEmpty) _moveFocusFrom(index);
    _claimInitialFocus();
  }

  /// The focused row emptied (its last title marked watched while watched
  /// ones are hidden): focus goes to the nearest row below, else above.
  void _moveFocusFrom(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final i in [
        for (var i = index + 1; i < _rows.length; i++) i,
        for (var i = index - 1; i >= 0; i--) i,
      ]) {
        if (_hasItems(i)) {
          _rowNodes[i].requestFocus();
          return;
        }
      }
      _searchNode.requestFocus();
    });
  }

  /// Focus starts on the topmost row with content, as on the home screen,
  /// once every row above it has arrived. A row that loads later never
  /// takes it away.
  void _claimInitialFocus() {
    if (_focusClaimed) return;
    for (var i = 0; i < _rows.length; i++) {
      final row = _rows[i];
      if (row == null) return;
      if (row.isEmpty) continue;
      _focusClaimed = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _rowNodes[i].requestFocus();
      });
      return;
    }
  }

  /// After a change from the context menu, the rows are read again.
  void _reload() {
    widget.vault.repository.clear();
    setState(() => _load(keepRows: true));
  }

  @override
  void dispose() {
    _focusSettle?.cancel();
    for (final node in _rowNodes) {
      node.dispose();
    }
    _searchNode.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onFocusItem(AggregatedItem item) {
    if (item.id.startsWith(_seeAllPrefix)) return;
    // Settles for a moment so fast scrolling doesn't swap the backdrop and
    // the info area for every card passed.
    _focusSettle?.cancel();
    _focusSettle = Timer(const Duration(milliseconds: 120), () {
      if (mounted && _focused?.id != item.id) {
        setState(() => _focused = item);
      }
    });
  }

  bool _hasItems(int index) => (_rows[index] ?? const []).isNotEmpty;

  bool _onVerticalNavigation(int from, bool isUp) {
    var next = from;
    do {
      next += isUp ? -1 : 1;
    } while (next >= 0 && next < _rows.length && !_hasItems(next));
    if (next < 0) {
      _searchNode.requestFocus();
      unawaited(
        _scroll.animateTo(
          0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        ),
      );
      return true;
    }
    if (next >= _rows.length) return true;
    _rowNodes[next].requestFocus();
    final rowContext = _rowKeys[next].currentContext;
    if (rowContext != null) {
      unawaited(
        Scrollable.ensureVisible(
          rowContext,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        ),
      );
    }
    return true;
  }

  String? _backdropUrl(AggregatedItem? item) {
    if (item == null) return null;
    final images = widget.vault.client.imageApi;
    final raw = item.rawData;
    final own = item.backdropImageTags;
    if (own.isNotEmpty) {
      return images.getBackdropImageUrl(
        item.id,
        maxWidth: 1280,
        tag: own.first,
      );
    }
    final parentId = raw['ParentBackdropItemId']?.toString();
    final parentTags = raw['ParentBackdropImageTags'];
    if (parentId != null && parentTags is List && parentTags.isNotEmpty) {
      return images.getBackdropImageUrl(
        parentId,
        maxWidth: 1280,
        tag: parentTags.first.toString(),
      );
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final s = VaultStrings.of(context);
    final vault = widget.vault;
    return Scaffold(
      backgroundColor: AppColorScheme.background,
      body: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            child: FullscreenBackdropSwitcher(
              imageUrl: _backdropUrl(_focused),
              duration: const Duration(milliseconds: 400),
            ),
          ),
          const _Scrim(),
          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    _sidePadding,
                    12,
                    _sidePadding,
                    0,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          vault.vault.name,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: AppColorScheme.onSurface.withValues(
                                  alpha: 0.7,
                                ),
                              ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        focusNode: _searchNode,
                        tooltip: s.search,
                        icon: const Icon(Icons.search),
                        onPressed: () =>
                            GoRouter.of(context)
                                .push(VaultRoutes.search(vault.vault.id)),
                      ),
                      IconButton(
                        tooltip: s.lock,
                        icon: const Icon(Icons.lock_outline),
                        onPressed: () => VaultSessionController.instance.lock(
                          vault.scope,
                          vault.vault.id,
                          VaultLockReason.manual,
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: _sidePadding),
                  child: InfoArea(item: _focused),
                ),
                Expanded(child: _rowsList(s)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _rowsList(VaultStrings s) {
    final loading = _rows.any((r) => r == null);
    final empty = !loading && _rows.every((r) => r!.isEmpty);
    if (empty) return Center(child: Text(s.empty));
    return FocusTraversalGroup(
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.only(bottom: 48),
        itemCount: _specs.length + (loading ? 1 : 0),
        itemBuilder: (context, index) {
          if (index == _specs.length) {
            return const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final items = _rows[index];
          if (items == null || items.isEmpty) return const SizedBox.shrink();
          return _row(s, index, items);
        },
      ),
    );
  }

  Widget _row(VaultStrings s, int index, List<AggregatedItem> items) {
    final spec = _specs[index];
    final metrics = VaultCardMetrics.of(landscape: spec.landscape);
    final library = spec.library;
    final rowItems = [
      ...items,
      if (library != null)
        AggregatedItem(
          id: '$_seeAllPrefix${library.libraryId}',
          serverId: '',
          rawData: {'Name': s.seeAll},
        ),
    ];
    final images = widget.vault.client.imageApi;
    void open(AggregatedItem item) {
      if (item.id.startsWith(_seeAllPrefix)) {
        GoRouter.of(
          context,
        ).push(VaultRoutes.library(widget.vault.vault.id, library!.libraryId));
      } else {
        openVaultItem(context, item);
      }
    }

    return Column(
      key: _rowKeys[index],
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(_sidePadding, 16, 8, 0),
          child: Text(
            spec.title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: AppColorScheme.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        LockedFocusRow<AggregatedItem>(
          items: rowItems,
          itemKey: (item, _) => item.id,
          hubKey: 'vault:${widget.vault.vault.id}:$index',
          focusNode: _rowNodes[index],
          height: metrics.rowHeight + 8,
          itemExtent: metrics.width,
          itemSpacing: metrics.spacing,
          clipBehavior: metrics.expansion ? Clip.none : Clip.hardEdge,
          padding: EdgeInsets.fromLTRB(
            _sidePadding,
            metrics.headroom + 8,
            20,
            0,
          ),
          onIndexChanged: (_, item) => _onFocusItem(item),
          onVerticalNavigation: (isUp) => _onVerticalNavigation(index, isUp),
          onTap: (_, item) => open(item),
          onLongPress: (_, item) {
            if (item.id.startsWith(_seeAllPrefix)) return;
            showVaultItemMenu(context, item, onChanged: _reload);
          },
          itemBuilder: (context, item, _, isFocused) {
            if (item.id.startsWith(_seeAllPrefix)) {
              return Align(
                alignment: Alignment.topCenter,
                child: GridButtonCard(
                  icon: Icons.grid_view,
                  label: s.seeAll,
                  width: metrics.width,
                  height: metrics.imageHeight,
                  cardFocusExpansion: metrics.expansion,
                  externalIsFocused: isFocused,
                  onTap: () => open(item),
                ),
              );
            }
            return Align(
              alignment: Alignment.topCenter,
              child: VaultItemCard(
                item: item,
                images: images,
                metrics: metrics,
                externalIsFocused: isFocused,
                onChanged: _reload,
              ),
            );
          },
        ),
      ],
    );
  }
}

/// The same darkening as behind the home screen's rows.
class _Scrim extends StatelessWidget {
  const _Scrim();

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            AppColorScheme.scrim.withValues(alpha: 0.8),
            AppColorScheme.scrim.withValues(alpha: 0.4),
            AppColorScheme.scrim.withValues(alpha: 0.8),
          ],
          stops: const [0.0, 0.3, 1.0],
        ),
      ),
      child: const SizedBox.expand(),
    ),
  );
}
