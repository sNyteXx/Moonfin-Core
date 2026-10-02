import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:moonfin_design/moonfin_design.dart';
import 'package:server_core/server_core.dart';

import '../../../ui/screens/settings/settings_app_bar.dart';
import '../../../ui/widgets/adaptive/adaptive_list_section.dart';
import '../../../ui/widgets/settings/clean_settings_typography.dart';
import '../../../ui/widgets/settings/preference_tiles.dart';
import '../../../ui/widgets/settings/settings_panel.dart';
import '../../../ui/widgets/settings/settings_section_header.dart';
import '../../../util/platform_detection.dart';
import '../data/hidden_content_service.dart';
import '../data/vault_store.dart';
import '../hidden_vault.dart';
import '../model/tag_match.dart';
import '../model/vault_config.dart';
import '../session/vault_session.dart';
import 'vault_access.dart';
import 'vault_routes.dart';
import 'vault_strings.dart';
import 'widgets/vault_text_input.dart';

/// The way into the configuration: set a PIN the first time, ask for it
/// every time after.
abstract final class VaultSettingsEntry {
  static Future<void> open(BuildContext context) async {
    final scope = HiddenVault.activeScope;
    if (scope == null || HiddenVault.activeService == null) return;
    final ok = VaultAccess.hasPin(scope)
        ? await VaultAccess.verifyPin(context, scope)
        : await VaultAccess.setPin(context, scope);
    if (!ok || !context.mounted) return;
    await context.pushSettingsScreen(const VaultSettingsScreen());
  }
}

/// A library as the server lists it.
class _LibraryOption {
  final String id;
  final String name;
  final String? collectionType;

  const _LibraryOption(this.id, this.name, this.collectionType);
}

/// Tags per library, kept for a while so flipping between libraries in the
/// editor doesn't refetch them.
class _TagCache {
  static const _maxAge = Duration(minutes: 10);
  static final Map<String, (DateTime, List<String>)> _entries = {};

  static Future<List<String>> load(
    ItemsApi api,
    VaultScope scope,
    String libraryId,
  ) async {
    final key = '${scope.key}#$libraryId';
    final cached = _entries[key];
    if (cached != null && DateTime.now().difference(cached.$1) < _maxAge) {
      return cached.$2;
    }
    final values = await api.getQueryFilters(parentId: libraryId);
    final seen = <String>{};
    final tags = [
      for (final tag in values.tags)
        if (tag.trim().isNotEmpty && seen.add(normalizeTag(tag))) tag.trim(),
    ]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    _entries[key] = (DateTime.now(), tags);
    return tags;
  }
}

Widget _tile(
  BuildContext context, {
  required Widget title,
  Widget? subtitle,
  IconData? icon,
  Widget? trailing,
  bool? checked,
  bool enabled = true,
  bool autofocus = false,
  VoidCallback? onTap,
}) {
  return TvFocusHighlight(
    enabled: enabled,
    builder: (_, focused) {
      final color = !enabled
          ? AppColorScheme.onSurface.withValues(alpha: 0.38)
          : focused
          ? AppColors.black.withValues(alpha: 0.87)
          : AppColorScheme.onSurface;
      final leadingIcon = checked == null
          ? icon
          : (checked ? Icons.check_box : Icons.check_box_outline_blank);
      return ListTile(
        enabled: enabled,
        autofocus: autofocus && PlatformDetection.isTV,
        focusColor: Colors.transparent,
        hoverColor: Colors.transparent,
        leading: leadingIcon == null
            ? null
            : Icon(leadingIcon, color: color.withValues(alpha: 0.75)),
        title: DefaultTextStyle.merge(
          style: TextStyle(color: color),
          child: title,
        ),
        subtitle: subtitle == null
            ? null
            : DefaultTextStyle.merge(
                style: TextStyle(color: color.withValues(alpha: 0.7)),
                child: subtitle,
              ),
        trailing: trailing,
        onTap: enabled ? onTap : null,
      );
    },
  );
}

Future<String?> _askText(
  BuildContext context, {
  required String title,
  required String hint,
  String initial = '',
}) {
  final controller = TextEditingController(text: initial);
  final s = VaultStrings.of(context);
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 420,
        child: VaultTextInput(
          controller: controller,
          hint: hint,
          autofocus: true,
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(s.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(controller.text),
          child: Text(s.save),
        ),
      ],
    ),
  ).whenComplete(controller.dispose);
}

/// Edits the vaults of the signed in account. Changes are kept as a draft and
/// applied together, since applying rebuilds the hidden index.
class VaultSettingsScreen extends StatefulWidget {
  const VaultSettingsScreen({super.key});

  @override
  State<VaultSettingsScreen> createState() => _VaultSettingsScreenState();
}

class _VaultSettingsScreenState extends State<VaultSettingsScreen> {
  late final VaultScope _scope;
  late final HiddenContentService _service;
  late VaultConfig _draft;
  bool _dirty = false;
  bool _saving = false;
  List<_LibraryOption>? _libraries;
  Object? _librariesError;

  @override
  void initState() {
    super.initState();
    _scope = HiddenVault.activeScope!;
    _service = HiddenVault.activeService!;
    _draft = _service.config;
    unawaited(_loadLibraries());
  }

  @override
  void dispose() {
    // Leaving with changes still applies them; the rebuild runs on its own.
    if (_dirty && !_saving) unawaited(_apply(_draft));
    super.dispose();
  }

  Future<void> _loadLibraries() async {
    try {
      final client = HiddenVault.activeUnfilteredClient!;
      final views = await client.userViewsApi.getUserViews(includeHidden: true);
      final options = [
        for (final raw in (views['Items'] as List?) ?? const [])
          if (raw is Map && raw['Id'] != null)
            _LibraryOption(
              raw['Id'].toString(),
              raw['Name']?.toString() ?? '',
              raw['CollectionType']?.toString(),
            ),
      ];
      if (mounted) setState(() => _libraries = options);
    } catch (error) {
      if (mounted) setState(() => _librariesError = error);
    }
  }

  void _update(VaultConfig next) => setState(() {
    _draft = next;
    _dirty = true;
  });

  Future<void> _apply(VaultConfig config) async {
    final before = _service.config;
    final rulesChanged = config.fingerprint != before.fingerprint;
    await _service.saveConfig(config);
    // A vault that was removed while open closes with it.
    final session = VaultSessionController.instance;
    for (final vault in before.vaults) {
      if (_service.config.vault(vault.id) == null) {
        session.lock(_scope, vault.id, VaultLockReason.configChanged);
      }
    }
    if (rulesChanged) HiddenVault.refreshNormalScreens();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await _apply(_draft);
      if (!mounted) return;
      setState(() {
        _dirty = false;
        _draft = _service.config;
      });
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(VaultStrings.of(context).saved)));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(VaultStrings.of(context).loadFailed)),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _newVaultId() {
    final random = Random.secure();
    return List.generate(
      12,
      (_) => random.nextInt(36).toRadixString(36),
    ).join();
  }

  Future<void> _editVault(VaultDefinition vault) async {
    await context.pushSettingsScreen(
      _VaultEditorScreen(
        scope: _scope,
        initial: vault,
        libraries: _libraries ?? const [],
        claimedElsewhere: {
          for (final other in _draft.vaults)
            if (other.id != vault.id)
              for (final lib in other.libraries) lib.libraryId,
        },
        onChanged: (updated) {
          final vaults = [
            for (final v in _draft.vaults)
              if (v.id != vault.id) v else ?updated,
          ];
          _update(_draft.copyWith(vaults: vaults));
        },
      ),
    );
  }

  Future<void> _addVault(VaultStrings s) async {
    final vault = VaultDefinition(id: _newVaultId(), name: s.defaultVaultName);
    _update(_draft.copyWith(vaults: [..._draft.vaults, vault]));
    await _editVault(vault);
  }

  Future<void> _openVault(VaultDefinition vault) async {
    if (_dirty) await _save();
    if (!mounted) return;
    final router = GoRouter.of(context);
    VaultSessionController.instance.unlock(_scope, vault.id);
    final root = Navigator.of(context, rootNavigator: true);
    if (root.canPop()) root.pop();
    unawaited(router.push(VaultRoutes.home(vault.id)));
  }

  Future<void> _removeAll(VaultStrings s) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: Text(s.removeAllConfirm),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(s.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(s.confirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    VaultSessionController.instance.onActiveScopeChanged(null);
    _draft = VaultConfig(vaults: const []);
    _dirty = false;
    await _apply(_draft);
    await VaultAccess.pinFor(_scope)?.removePin();
    if (mounted) Navigator.of(context).pop();
  }

  String _librarySummary(VaultDefinition vault) {
    if (vault.libraries.isEmpty) return '—';
    return [
      for (final lib in vault.libraries) '${lib.name} (${lib.tags.length})',
    ].join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final s = VaultStrings.of(context);
    final settings = _draft.settings;
    final index = _service.index;
    return withCleanSettingsTypography(
      context,
      Scaffold(
        appBar: buildSettingsAppBar(context, Text(s.configTitle)),
        body: ListView(
          children: [
            if (_saving) const LinearProgressIndicator(),
            adaptiveListSection(
              children: [
                _tile(
                  context,
                  autofocus: true,
                  icon: Icons.save_outlined,
                  title: Text(_saving ? s.saving : s.save),
                  enabled: _dirty && !_saving,
                  onTap: _save,
                ),
              ],
            ),
            SettingsSectionHeader(s.vaults),
            if (_librariesError != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(s.loadFailed),
              ),
            if (_draft.vaults.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(s.noVaults),
              ),
            adaptiveListSection(
              children: [
                for (final vault in _draft.vaults)
                  _tile(
                    context,
                    icon: Icons.folder_special_outlined,
                    title: Text(vault.name),
                    subtitle: Text(_librarySummary(vault)),
                    onTap: () => _editVault(vault),
                  ),
                _tile(
                  context,
                  icon: Icons.add,
                  title: Text(s.addVault),
                  enabled: _libraries != null,
                  onTap: () => _addVault(s),
                ),
              ],
            ),
            if (_service.config.vaults.any((v) => v.hasRules)) ...[
              SettingsSectionHeader(s.open),
              adaptiveListSection(
                children: [
                  for (final vault in _service.config.vaults)
                    if (vault.hasRules)
                      _tile(
                        context,
                        icon: Icons.arrow_forward,
                        title: Text('${s.open}: ${vault.name}'),
                        subtitle: index == null
                            ? null
                            : Text(
                                s.indexSummary(index.idsOf(vault.id).length),
                              ),
                        onTap: () => _openVault(vault),
                      ),
                  _tile(
                    context,
                    icon: Icons.refresh,
                    title: Text(s.rebuildIndex),
                    onTap: () async {
                      await _service.refreshIndex();
                      if (mounted) setState(() {});
                    },
                  ),
                ],
              ),
            ],
            SettingsSectionHeader(s.session),
            adaptiveListSection(
              children: [
                _tile(
                  context,
                  icon: Icons.timer_outlined,
                  title: Text(s.autoLock),
                  subtitle: Text(s.minutes(settings.autoLockMinutes)),
                  onTap: () {
                    const choices = VaultSettings.autoLockChoices;
                    final at = choices.indexOf(settings.autoLockMinutes);
                    final next = choices[(at + 1) % choices.length];
                    _update(
                      _draft.copyWith(
                        settings: settings.copyWith(autoLockMinutes: next),
                      ),
                    );
                  },
                ),
                _tile(
                  context,
                  checked: settings.lockOnLeave,
                  title: Text(s.lockOnLeave),
                  subtitle: Text(s.lockOnLeaveSubtitle),
                  onTap: () => _update(
                    _draft.copyWith(
                      settings: settings.copyWith(
                        lockOnLeave: !settings.lockOnLeave,
                      ),
                    ),
                  ),
                ),
                _tile(
                  context,
                  icon: Icons.pin_outlined,
                  title: Text(s.changePin),
                  onTap: () => VaultAccess.setPin(context, _scope),
                ),
                _tile(
                  context,
                  icon: Icons.delete_outline,
                  title: Text(s.removeAll),
                  onTap: () => _removeAll(s),
                ),
              ],
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

class _VaultEditorScreen extends StatefulWidget {
  final VaultScope scope;
  final VaultDefinition initial;
  final List<_LibraryOption> libraries;
  final Set<String> claimedElsewhere;
  final ValueChanged<VaultDefinition?> onChanged;

  const _VaultEditorScreen({
    required this.scope,
    required this.initial,
    required this.libraries,
    required this.claimedElsewhere,
    required this.onChanged,
  });

  @override
  State<_VaultEditorScreen> createState() => _VaultEditorScreenState();
}

class _VaultEditorScreenState extends State<_VaultEditorScreen> {
  late VaultDefinition _vault = widget.initial;

  void _set(VaultDefinition next) {
    setState(() => _vault = next);
    widget.onChanged(next);
  }

  void _toggleLibrary(_LibraryOption option) {
    final existing = _vault.library(option.id);
    final libraries = existing != null
        ? [
            for (final lib in _vault.libraries)
              if (lib.libraryId != option.id) lib,
          ]
        : [
            ..._vault.libraries,
            VaultLibrary(
              libraryId: option.id,
              name: option.name,
              collectionType: option.collectionType,
            ),
          ];
    final trigger = _vault.triggerLibraryId;
    _set(
      _vault.copyWith(
        libraries: libraries,
        clearTrigger: trigger != null && !libraries.any((l) => l.libraryId == trigger),
      ),
    );
  }

  void _cycleTrigger() {
    final options = <String?>[null, for (final lib in _vault.libraries) lib.libraryId];
    final at = options.indexOf(_vault.triggerLibraryId);
    final next = options[(at + 1) % options.length];
    _set(
      next == null
          ? _vault.copyWith(clearTrigger: true)
          : _vault.copyWith(triggerLibraryId: next),
    );
  }

  Future<void> _rename(VaultStrings s) async {
    final name = await _askText(
      context,
      title: s.vaultName,
      hint: s.vaultName,
      initial: _vault.name,
    );
    if (name == null || name.trim().isEmpty) return;
    _set(_vault.copyWith(name: name.trim()));
  }

  Future<void> _editTags(VaultLibrary library) async {
    await context.pushSettingsScreen(
      _TagPickerScreen(
        scope: widget.scope,
        library: library,
        onChanged: (tags) {
          _set(
            _vault.copyWith(
              libraries: [
                for (final lib in _vault.libraries)
                  lib.libraryId == library.libraryId
                      ? lib.copyWith(tags: tags)
                      : lib,
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = VaultStrings.of(context);
    String nameOf(String? id) =>
        _vault.library(id ?? '')?.name ?? s.triggerNone;
    return withCleanSettingsTypography(
      context,
      Scaffold(
        appBar: buildSettingsAppBar(context, Text(_vault.name)),
        body: ListView(
          children: [
            adaptiveListSection(
              children: [
                _tile(
                  context,
                  autofocus: true,
                  icon: Icons.edit_outlined,
                  title: Text(s.vaultName),
                  subtitle: Text(_vault.name),
                  onTap: () => _rename(s),
                ),
                _tile(
                  context,
                  icon: Icons.touch_app_outlined,
                  title: Text(s.trigger),
                  subtitle: Text(
                    _vault.triggerLibraryId == null
                        ? s.triggerNone
                        : '${nameOf(_vault.triggerLibraryId)} · '
                              '${s.triggerHint(nameOf(_vault.triggerLibraryId))}',
                  ),
                  onTap: _cycleTrigger,
                ),
              ],
            ),
            SettingsSectionHeader(s.libraries),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(s.librariesHint),
            ),
            adaptiveListSection(
              children: [
                for (final option in widget.libraries)
                  _tile(
                    context,
                    checked: _vault.library(option.id) != null,
                    enabled: !widget.claimedElsewhere.contains(option.id),
                    title: Text(option.name),
                    subtitle: option.collectionType == null
                        ? null
                        : Text(option.collectionType!),
                    onTap: () => _toggleLibrary(option),
                  ),
              ],
            ),
            if (_vault.libraries.isNotEmpty) ...[
              SettingsSectionHeader(s.hiddenTags),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(s.hiddenTagsHint),
              ),
              adaptiveListSection(
                children: [
                  for (final library in _vault.libraries)
                    _tile(
                      context,
                      icon: Icons.sell_outlined,
                      title: Text(s.hiddenTagsFor(library.name)),
                      subtitle: Text(
                        library.tags.isEmpty
                            ? s.noTagsYet
                            : library.tags.join(', '),
                      ),
                      onTap: () => _editTags(library),
                    ),
                ],
              ),
            ],
            adaptiveListSection(
              children: [
                _tile(
                  context,
                  icon: Icons.delete_outline,
                  title: Text(s.removeVault),
                  onTap: () {
                    widget.onChanged(null);
                    Navigator.of(context).pop();
                  },
                ),
              ],
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

class _TagPickerScreen extends StatefulWidget {
  final VaultScope scope;
  final VaultLibrary library;
  final ValueChanged<List<String>> onChanged;

  const _TagPickerScreen({
    required this.scope,
    required this.library,
    required this.onChanged,
  });

  @override
  State<_TagPickerScreen> createState() => _TagPickerScreenState();
}

class _TagPickerScreenState extends State<_TagPickerScreen> {
  late List<String> _selected = [...widget.library.tags];
  List<String>? _available;
  Object? _error;
  final _filter = TextEditingController();

  @override
  void initState() {
    super.initState();
    _filter.addListener(() => setState(() {}));
    unawaited(_load());
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      // The unfiltered API: the normal one keeps hidden tags out of pickers.
      final api = HiddenVault.activeUnfilteredClient!.itemsApi;
      final tags = await _TagCache.load(
        api,
        widget.scope,
        widget.library.libraryId,
      );
      if (mounted) setState(() => _available = tags);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  bool _isSelected(String tag) {
    final normalized = normalizeTag(tag);
    return _selected.any((t) => normalizeTag(t) == normalized);
  }

  void _toggle(String tag) {
    final normalized = normalizeTag(tag);
    setState(() {
      if (_isSelected(tag)) {
        _selected = [
          for (final t in _selected)
            if (normalizeTag(t) != normalized) t,
        ];
      } else {
        _selected = [..._selected, tag];
      }
    });
    widget.onChanged(_selected);
  }

  Future<void> _addCustom(VaultStrings s) async {
    final tag = await _askText(
      context,
      title: s.addCustomTag,
      hint: s.customTagHint,
    );
    if (tag == null || normalizeTag(tag).isEmpty) return;
    if (!_isSelected(tag)) _toggle(tag.trim());
  }

  @override
  Widget build(BuildContext context) {
    final s = VaultStrings.of(context);
    final query = normalizeTag(_filter.text);
    final available = _available ?? const <String>[];
    final selectedNormalized = {for (final t in _selected) normalizeTag(t)};
    final others = [
      for (final tag in available)
        if (!selectedNormalized.contains(normalizeTag(tag)) &&
            (query.isEmpty || normalizeTag(tag).contains(query)))
          tag,
    ];
    return withCleanSettingsTypography(
      context,
      Scaffold(
        appBar: buildSettingsAppBar(
          context,
          Text(s.hiddenTagsFor(widget.library.name)),
        ),
        body: ListView(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(s.hiddenTagsHint),
            ),
            adaptiveListSection(
              children: [
                _tile(
                  context,
                  autofocus: true,
                  icon: Icons.add,
                  title: Text(s.addCustomTag),
                  onTap: () => _addCustom(s),
                ),
                for (final tag in _selected)
                  _tile(
                    context,
                    checked: true,
                    title: Text(tag),
                    onTap: () => _toggle(tag),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: VaultTextInput(
                controller: _filter,
                hint: s.filterTags,
                onSubmitted: (_) {},
              ),
            ),
            if (_available == null && _error == null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 12),
                    Text(s.loadingTags),
                  ],
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(s.tagsLoadFailed),
              ),
            if (others.isNotEmpty)
              adaptiveListSection(
                children: [
                  for (final tag in others)
                    _tile(
                      context,
                      checked: false,
                      title: Text(tag),
                      onTap: () => _toggle(tag),
                    ),
                ],
              ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}
