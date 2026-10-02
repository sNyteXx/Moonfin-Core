import 'package:flutter/material.dart';
import 'package:moonfin_design/moonfin_design.dart';

import '../../../data/models/aggregated_item.dart';
import '../model/vault_config.dart';
import 'vault_screen_scope.dart';
import 'vault_strings.dart';
import 'widgets/vault_item_card.dart';

/// All hidden titles of one vault library, paged from the server with a tag
/// query so ordinary titles are never fetched just to be dropped.
class VaultLibraryScreen extends StatelessWidget {
  final String vaultId;
  final String libraryId;

  const VaultLibraryScreen({
    super.key,
    required this.vaultId,
    required this.libraryId,
  });

  @override
  Widget build(BuildContext context) => VaultScreenScope(
    vaultId: vaultId,
    builder: (context, vault) {
      final library = vault.vault.library(libraryId);
      if (library == null || !library.hasTags) {
        return Scaffold(
          backgroundColor: AppColorScheme.background,
          body: Center(child: Text(VaultStrings.of(context).empty)),
        );
      }
      return _VaultLibraryGrid(vault: vault, library: library);
    },
  );
}

class _VaultLibraryGrid extends StatefulWidget {
  final VaultContext vault;
  final VaultLibrary library;

  const _VaultLibraryGrid({required this.vault, required this.library});

  @override
  State<_VaultLibraryGrid> createState() => _VaultLibraryGridState();
}

class _VaultLibraryGridState extends State<_VaultLibraryGrid> {
  static const _pageSize = 48;

  final List<AggregatedItem> _items = [];
  final Set<String> _ids = {};
  int _rawOffset = 0;
  int? _total;
  bool _loading = false;
  bool _done = false;
  bool _scheduled = false;
  Object? _error;

  /// Paging is asked for while the grid builds, so it starts after the frame.
  void _scheduleLoadMore() {
    if (_scheduled || _loading || _done || _error != null) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) _loadMore();
    });
  }

  @override
  void initState() {
    super.initState();
    _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || _done) return;
    setState(() => _loading = true);
    try {
      final page = await widget.vault.repository.libraryPage(
        widget.library,
        startIndex: _rawOffset,
        limit: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _rawOffset += page.rawCount;
        _total = page.totalCount;
        for (final item in page.items) {
          if (_ids.add(item.id)) _items.add(item);
        }
        _done =
            page.rawCount < _pageSize ||
            (_total != null && _rawOffset >= _total!);
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = VaultStrings.of(context);
    return Scaffold(
      backgroundColor: AppColorScheme.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(48, 24, 48, 12),
              child: Text(
                widget.library.name,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            Expanded(child: _body(s)),
          ],
        ),
      ),
    );
  }

  Widget _body(VaultStrings s) {
    if (_items.isEmpty && _loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_items.isEmpty && _error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(s.loadFailed),
            const SizedBox(height: 12),
            FilledButton(
              autofocus: true,
              onPressed: _loadMore,
              child: Text(s.retry),
            ),
          ],
        ),
      );
    }
    if (_items.isEmpty) return Center(child: Text(s.empty));
    return FocusTraversalGroup(
      child: GridView.builder(
        padding: const EdgeInsets.fromLTRB(48, 0, 48, 48),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 170,
          childAspectRatio: 150 / 290,
          crossAxisSpacing: 16,
          mainAxisSpacing: 16,
        ),
        itemCount: _items.length,
        itemBuilder: (context, index) {
          if (index >= _items.length - 12) _scheduleLoadMore();
          return VaultItemCard(
            item: _items[index],
            images: widget.vault.client.imageApi,
            autofocus: index == 0,
          );
        },
      ),
    );
  }
}
