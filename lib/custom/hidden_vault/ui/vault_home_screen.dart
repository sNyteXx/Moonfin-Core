import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:moonfin_design/moonfin_design.dart';

import '../../../data/models/aggregated_item.dart';
import '../model/vault_config.dart';
import '../session/vault_session.dart';
import 'vault_routes.dart';
import 'vault_screen_scope.dart';
import 'vault_strings.dart';
import 'widgets/vault_item_card.dart';

/// The vault's own small home: continue watching, next up, recently added and
/// one row per library, all limited to this vault's hidden content.
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
  final Future<List<AggregatedItem>> items;
  final bool landscape;
  final VaultLibrary? library;

  _RowSpec(this.title, this.items, {this.landscape = false, this.library});
}

class _VaultHome extends StatefulWidget {
  final VaultContext vault;

  const _VaultHome({required this.vault});

  @override
  State<_VaultHome> createState() => _VaultHomeState();
}

class _VaultHomeState extends State<_VaultHome> {
  List<_RowSpec>? _rows;
  bool _focusClaimed = false;

  void _load(VaultStrings s) {
    final repo = widget.vault.repository;
    _rows = [
      _RowSpec(s.continueWatching, repo.continueWatching(), landscape: true),
      _RowSpec(s.nextUp, repo.nextUp(), landscape: true),
      _RowSpec(s.recentlyAdded, repo.recentlyAdded()),
      for (final library in repo.libraries)
        _RowSpec(library.name, repo.libraryRow(library), library: library),
    ];
  }

  bool _claimFocus() {
    if (_focusClaimed) return false;
    _focusClaimed = true;
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final s = VaultStrings.of(context);
    if (_rows == null) _load(s);
    final vault = widget.vault;
    return Scaffold(
      backgroundColor: AppColorScheme.background,
      body: SafeArea(
        child: FocusTraversalGroup(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(0, 24, 0, 48),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 48),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        vault.vault.name,
                        style: Theme.of(context).textTheme.headlineSmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      tooltip: s.search,
                      icon: const Icon(Icons.search),
                      onPressed: () => GoRouter.of(
                        context,
                      ).push(VaultRoutes.search(vault.vault.id)),
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
              for (final row in _rows!)
                _VaultRow(
                  spec: row,
                  vault: vault,
                  claimFocus: _claimFocus,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VaultRow extends StatelessWidget {
  final _RowSpec spec;
  final VaultContext vault;
  final bool Function() claimFocus;

  const _VaultRow({
    required this.spec,
    required this.vault,
    required this.claimFocus,
  });

  @override
  Widget build(BuildContext context) {
    final s = VaultStrings.of(context);
    final width = spec.landscape ? 260.0 : 150.0;
    final height = spec.landscape ? width * 9 / 16 + 70 : width * 3 / 2 + 70;
    return FutureBuilder<List<AggregatedItem>>(
      future: spec.items,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return SizedBox(
            height: height + 48,
            child: const Center(child: CircularProgressIndicator()),
          );
        }
        final items = snapshot.data ?? const <AggregatedItem>[];
        if (items.isEmpty) return const SizedBox.shrink();
        final autofocusFirst = claimFocus();
        final library = spec.library;
        return Padding(
          padding: const EdgeInsets.only(top: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 48),
                child: Text(
                  spec.title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: height,
                child: FocusTraversalGroup(
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 48),
                    itemCount: items.length + (library != null ? 1 : 0),
                    separatorBuilder: (_, _) => const SizedBox(width: 16),
                    itemBuilder: (context, index) {
                      if (index == items.length) {
                        return _SeeAllTile(
                          label: s.seeAll,
                          width: width,
                          onTap: () => GoRouter.of(context).push(
                            VaultRoutes.library(
                              vault.vault.id,
                              library!.libraryId,
                            ),
                          ),
                        );
                      }
                      return VaultItemCard(
                        item: items[index],
                        images: vault.client.imageApi,
                        landscape: spec.landscape,
                        width: width,
                        autofocus: autofocusFirst && index == 0,
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SeeAllTile extends StatelessWidget {
  final String label;
  final double width;
  final VoidCallback onTap;

  const _SeeAllTile({
    required this.label,
    required this.width,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Align(
        alignment: Alignment.topCenter,
        child: AspectRatio(
          aspectRatio: 2 / 3,
          child: OutlinedButton(onPressed: onTap, child: Text(label)),
        ),
      ),
    );
  }
}
