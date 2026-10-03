import 'package:flutter/widgets.dart';

/// The vault's own strings, English and German.
///
/// Kept out of the app's ARB files on purpose: those are rewritten by
/// translation syncs upstream all the time, and a fork that adds keys there
/// conflicts on every merge.
class VaultStrings {
  final bool _de;

  const VaultStrings._(this._de);

  static VaultStrings of(BuildContext context) {
    final locale = Localizations.maybeLocaleOf(context);
    return VaultStrings._(locale?.languageCode == 'de');
  }

  String _t(String en, String de) => _de ? de : en;

  // Settings entry. Deliberately plain, it must not advertise anything.

  String get configTitle => _t('Private content', 'Privater Bereich');
  String get vaults => _t('Areas', 'Bereiche');
  String get addVault => _t('Add area', 'Bereich hinzufügen');
  String get noVaults => _t(
    'Nothing configured yet. Add an area and pick its libraries and tags.',
    'Noch nichts eingerichtet. Lege einen Bereich an und wähle Bibliotheken und Tags.',
  );
  String get vaultName => _t('Name', 'Name');
  String get defaultVaultName => _t('Private', 'Privat');
  String get libraries => _t('Libraries', 'Bibliotheken');
  String get librariesHint => _t(
    'A library can belong to one area only.',
    'Eine Bibliothek kann nur zu einem Bereich gehören.',
  );
  String get hiddenTags => _t('Hidden tags', 'Versteckte Tags');
  String hiddenTagsFor(String library) =>
      _t('Hidden tags in $library', 'Versteckte Tags in $library');
  String get hiddenTagsHint => _t(
    'Items with any of these tags (exact, case ignored) are hidden.',
    'Einträge mit einem dieser Tags (exakt, ohne Groß-/Kleinschreibung) werden versteckt.',
  );
  String get noTagsYet => _t('No tags selected', 'Keine Tags ausgewählt');
  String tagCount(int n) => _de ? '$n Tags' : (n == 1 ? '1 tag' : '$n tags');
  String get addCustomTag => _t('Add tag manually', 'Tag manuell hinzufügen');
  String get customTagHint => _t('Tag', 'Tag');
  String get loadingTags => _t('Loading tags…', 'Tags werden geladen…');
  String get tagsLoadFailed =>
      _t('Could not load tags.', 'Tags konnten nicht geladen werden.');
  String get filterTags => _t('Filter tags', 'Tags filtern');
  String get removeVault => _t('Remove area', 'Bereich entfernen');
  String get save => _t('Save', 'Speichern');
  String get saving => _t('Saving…', 'Speichern…');
  String get saved => _t('Saved', 'Gespeichert');
  String get open => _t('Open', 'Öffnen');
  String get session => _t('Locking', 'Sperren');
  String get autoLock =>
      _t('Lock after inactivity', 'Sperren nach Inaktivität');
  String minutes(int n) => _t('$n minutes', '$n Minuten');
  String get lockOnLeave => _t('Lock when leaving', 'Beim Verlassen sperren');
  String get lockOnLeaveSubtitle => _t(
    'Leaving the area always asks for the PIN again.',
    'Nach dem Verlassen wird die PIN erneut abgefragt.',
  );
  String get changePin => _t('Change PIN', 'PIN ändern');
  String get removeAll => _t('Remove everything', 'Alles entfernen');
  String get removeAllConfirm => _t(
    'Remove all areas, rules and the PIN?',
    'Alle Bereiche, Regeln und die PIN entfernen?',
  );
  String get cancel => _t('Cancel', 'Abbrechen');
  String get confirm => _t('Remove', 'Entfernen');
  String get thisDevice => _t('This device', 'Dieses Gerät');
  String get syncTitle =>
      _t('Sync across devices', 'Geräteübergreifend synchronisieren');
  String get syncSubtitle => _t(
    'Areas, libraries and tags travel through your Jellyfin account. The PIN '
        'stays on each device.',
    'Bereiche, Bibliotheken und Tags laufen über dein Jellyfin-Konto. Die PIN '
        'bleibt auf jedem Gerät eigen.',
  );
  String get syncing => _t('Syncing…', 'Wird abgeglichen…');
  String get syncedFromServer => _t(
    'Took the newer settings from another device.',
    'Neuere Einstellungen eines anderen Geräts übernommen.',
  );
  String get biometricToggle => _t(
    'Unlock with fingerprint or face',
    'Mit Fingerabdruck oder Gesicht entsperren',
  );
  String get biometricSubtitle => _t(
    'The PIN still works and is asked for when this fails.',
    'Die PIN funktioniert weiter und wird abgefragt, wenn das fehlschlägt.',
  );
  String get biometricPrompt =>
      _t('Unlock private content', 'Privaten Bereich entsperren');
  String get usePin => _t('Use PIN', 'PIN verwenden');
  String indexSummary(int n) =>
      _t('$n items currently hidden', '$n Einträge aktuell versteckt');
  String get rebuildIndex => _t('Refresh now', 'Jetzt aktualisieren');

  // Vault screens.
  String get continueWatching => _t('Continue watching', 'Weiterschauen');
  String get nextUp => _t('Next up', 'Als Nächstes');
  String get recentlyAdded => _t('Recently added', 'Kürzlich hinzugefügt');
  String get search => _t('Search', 'Suchen');
  String get searchHint => _t('Search…', 'Suchen…');
  String get lock => _t('Lock', 'Sperren');
  String get empty => _t('Nothing here', 'Nichts vorhanden');
  String get noResults => _t('No results', 'Keine Ergebnisse');
  String get loadFailed =>
      _t('Could not load this.', 'Konnte nicht geladen werden.');
  String get retry => _t('Retry', 'Erneut versuchen');
  String get seeAll => _t('See all', 'Alle anzeigen');
}
