import 'package:flutter/material.dart';
import 'package:moonfin_design/moonfin_design.dart';

import '../../../data/models/aggregated_item.dart';
import 'vault_screen_scope.dart';
import 'vault_strings.dart';
import 'widgets/vault_item_card.dart';
import 'widgets/vault_text_input.dart';

/// Searches this vault's hidden content only. The normal search never sees
/// it, unlocked or not.
class VaultSearchScreen extends StatelessWidget {
  final String vaultId;

  const VaultSearchScreen({super.key, required this.vaultId});

  @override
  Widget build(BuildContext context) => VaultScreenScope(
    vaultId: vaultId,
    builder: (context, vault) => _VaultSearch(vault: vault),
  );
}

class _VaultSearch extends StatefulWidget {
  final VaultContext vault;

  const _VaultSearch({required this.vault});

  @override
  State<_VaultSearch> createState() => _VaultSearchState();
}

class _VaultSearchState extends State<_VaultSearch> {
  final _controller = TextEditingController();
  Future<List<AggregatedItem>>? _results;
  int _generation = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _search(String query) {
    final generation = ++_generation;
    final future = widget.vault.repository.search(query);
    setState(() => _results = future);
    future.whenComplete(() {
      if (mounted && generation == _generation) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = VaultStrings.of(context);
    return Scaffold(
      backgroundColor: AppColorScheme.background,
      body: SafeArea(
        child: FocusTraversalGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(48, 24, 48, 16),
                child: VaultTextInput(
                  controller: _controller,
                  hint: s.searchHint,
                  autofocus: true,
                  onSubmitted: _search,
                ),
              ),
              Expanded(
                child: _results == null
                    ? const SizedBox.shrink()
                    : FutureBuilder<List<AggregatedItem>>(
                        future: _results,
                        builder: (context, snapshot) {
                          if (snapshot.connectionState !=
                              ConnectionState.done) {
                            return const Center(
                              child: CircularProgressIndicator(),
                            );
                          }
                          if (snapshot.hasError) {
                            return Center(child: Text(s.loadFailed));
                          }
                          final items = snapshot.data ?? const [];
                          if (items.isEmpty) {
                            return Center(child: Text(s.noResults));
                          }
                          return GridView.builder(
                            padding: const EdgeInsets.fromLTRB(48, 0, 48, 48),
                            gridDelegate:
                                const SliverGridDelegateWithMaxCrossAxisExtent(
                                  maxCrossAxisExtent: 170,
                                  childAspectRatio: 150 / 290,
                                  crossAxisSpacing: 16,
                                  mainAxisSpacing: 16,
                                ),
                            itemCount: items.length,
                            itemBuilder: (context, index) => VaultItemCard(
                              item: items[index],
                              images: widget.vault.client.imageApi,
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
