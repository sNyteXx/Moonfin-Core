# Hidden Content Vault (Custom-Erweiterung dieses Forks)

> Status: implementiert auf Branch `claude/affectionate-faraday-3vdq85`.
> Diese Erweiterung ist **fork-spezifisch** und bewusst so geschnitten, dass sie
> sich bei Upstream-Merges mit wenigen, klar markierten Hook-Zeilen pflegen lässt.

## 1. Ziel

Beliebige Jellyfin-Serien/-Filme anhand **frei konfigurierbarer Jellyfin-Tags**
vollständig aus der normalen Moonfin-Oberfläche entfernen und nur in einem
PIN-geschützten, unsichtbar erreichbaren *Vault* zeigen.

* Tags sind **nicht** hart verdrahtet (`ecchi`, `private`, … sind nur Beispiele).
* Matching ist **exakt und case-insensitive** (`Ecchi == ecchi`,
  aber `adult != adult animation`, `hidden != hidden gem`). Kein Substring-Match.
* Mehrere Tags pro Library: **Hide if ANY tag matches**.
* Tags werden **pro Library** eines Vaults gespeichert (Library-ID, nicht Name).
* Beliebig viele Vault-Gruppen (z. B. „Anime“ = Anime + Filme (Anime),
  „Serien/Filme“ = Serien + Filme). Eine Library gehört höchstens zu einem Vault.
* Zwei Visibility-Kontexte: **NORMAL** (Hidden immer raus) und **VAULT**
  (gezielt die Hidden-Inhalte eines Vaults). Unlock schaltet **nichts** global frei.

## 2. Architektur-Überblick

Alles Custom liegt unter `lib/custom/hidden_vault/` und
`test/custom/hidden_vault/`. Upstream-Dateien enthalten nur kleine Hooks
(siehe §11).

```
lib/custom/hidden_vault/
  hidden_vault.dart                 Fassade: alle Hooks, die Upstream-Code aufruft
  model/
    tag_match.dart                  normalizeTag(), extractTags() (Tags / TagItems)
    vault_config.dart               VaultConfig / VaultDefinition / VaultLibrary (+ Fingerprint)
    hidden_tag_policy.dart          Library-ID -> (Vault, Tag-Set); exaktes Matching
  data/
    vault_config_store.dart         Persistenz pro Server+User (PreferenceStore)
    hidden_content_index.dart       Hidden-Index (ID -> Vault/Library/Typ) + Builder + Codec
    item_tag_resolver.dart          gebündelte Tag-Auflösung unbekannter Serien/Items
    hidden_content_service.dart     pro Server+User: Policy, Index, Verdicts, Refresh
    hidden_content_registry.dart    Scope -> Service (auch im Background-Isolate)
    visibility_items_api.dart       ItemsApi-Decorator (der zentrale Leak-Schutz)
    visibility_media_server_client.dart  Client-Wrapper (ItemsApi/UserLibraryApi/InstantMix)
    virtual_pager.dart              virtuelles Paging + begrenztes Overfetching
    vault_repository.dart           VAULT-Kontext-Queries (serverseitig Tags=…)
  session/
    vault_session.dart              In-Memory-Unlock, Timeout, Lock-on-leave, Auto-Lock
    vault_pin.dart                  PinCodeUtil.vault(...)
  gate/
    hidden_content_gate.dart        Detail- und Playback-Gate
  ui/                               Vault-Home, Library-Grid, Suche, Settings, Strings
```

### 2.1 Warum ein `ItemsApi`-Decorator statt nur `withoutBlockedItems`

Die Analyse hat ergeben, dass der Blocked-Ratings-Filter (`withoutBlockedItems`)
zwar zentral gedacht ist, aber an rund einem Dutzend Stellen umgangen wird
(Screensaver, Shuffle, Genre-Artwork, Android Auto/CarPlay, Detail-Next-Up,
Buch-Serien, Downloads, Server-Remote-Play, …). Für „kein Leak“ reicht das nicht.

Moonfin hat aber bereits genau die passende Naht: `MediaServerClient` ist ein
Interface, und `ConnectivityAwareMediaServerClient` wickelt den echten Client
schon heute ein. Der Vault fügt eine weitere Schicht hinzu:

```
VisibilityMediaServerClient          <- NEU: filtert Item-Listen im NORMAL-Kontext
  └─ ConnectivityAwareMediaServerClient   (online/offline Routing, Upstream)
       └─ Jellyfin/Emby-Client            (Upstream)
```

Damit läuft **jede** Item-Liste (Home, Next Up, Resume, Latest, Recently
Released, Empfehlungen, Media Bar, Suche, Library-Grids, Genres, Favoriten,
Collections, Similar, Filmografie, Screensaver, Android-TV-Channels/Watch Next
– auch im Background-Isolate –, Shuffle, Android Auto, Playback-Queues,
Server-Remote-Play) durch dieselbe Prüfung, ohne dass die ~100 Aufrufstellen
angefasst werden. Auch zukünftige Upstream-Features sind automatisch abgedeckt.

Der bestehende `withoutBlockedItems`/`BlockedContentGate` bleibt unverändert;
beide Mechanismen werden nur an den Gates (Detail/Playback) zusammengeführt.

## 3. Datenfluss

### 3.1 Hidden-Index (statt „pro Seite Hidden-IDs nachladen“)

Eine Library-Zugehörigkeit steht **nicht** im Jellyfin-DTO (kein LibraryId-Feld).
Ein reiner Tag-Vergleich auf dem DTO könnte daher die Library-Scope-Regel
(„Anime-Tags dürfen die Serien-Library nicht betreffen“) nicht einhalten.

Darum baut der Service pro konfigurierter Library **eine** serverseitige Query:

```
GET /Users/{u}/Items?ParentId=<libraryId>&Recursive=true
    &Tags=<tag1>|<tag2>&Fields=Tags&ImageTypeLimit=0&Limit=1000
```

* Jellyfin 12 (verifiziert im Quellcode, `BaseItemRepository.TranslateQuery.cs`,
  master 2026-10-01): `Tags` ist pipe-getrennt und hat **OR-Semantik**
  (`ItemValues.Any(CleanValue ∈ tags)`). Eine Query pro Library genügt.
* Der Server normalisiert (`GetCleanValue`: Diakritika entfernen, lowercase,
  Satzzeichen -> Leerzeichen). Das ist eine Obermenge des exakten Matchings;
  der Client **validiert jedes Ergebnis exakt** über das `Tags`-Feld.
* Ergebnis: `Map<ItemId, (vaultId, libraryId, type)>` – bei 150 `ecchi`-Serien
  wenige KB. Kein Laden von 793 Serien / 23.548 Episoden.
* Persistiert pro Server+User (PreferenceStore), versioniert mit dem
  Config-Fingerprint. App-Start: persistierter Index sofort nutzbar,
  Refresh im Hintergrund wenn älter als 10 min.

### 3.2 Normal-Filter (synchron, O(1) pro Item)

```
hidden(item) =
     item.Id      ∈ Index
  ∨  item.SeriesId ∈ Index        (Episoden/Staffeln erben von der Serie)
  ∨  item.SeasonId ∈ Index
  ∨  BoxSet/Playlist mit eigenem passendem Tag
  ∨  Verdacht (siehe 3.3)
```

### 3.3 Aktualität ohne N+1

* **Eigene Tags** von Serien/Filmen kommen im normalen Request mit: Der
  Decorator hängt `Tags` an vorhandene `Fields`-Listen an (nur wenn ein Vault
  aktiv ist). Passt ein Tag, das Item ist aber nicht im Index -> *Verdacht*.
* **Episoden/Staffeln**, deren Serie weder im Index noch im Prüf-Cache ist,
  werden pro Response **gesammelt** und mit **einem** Batch-Request
  `getItems(ids: [...], fields: Tags)` aufgelöst (Chunk 100, Coalescing über
  parallele Rows, In-Flight-Dedupe). Ergebnis wird mit TTL gecacht und
  persistiert. 20 Episoden aus 3 Serien => max. 1 Request.
* Ein Verdacht löst **einen** Index-Refresh aus (Single-Flight, begrenzt),
  danach ist die Entscheidung exakt (in Scope -> hidden, sonst als
  `outOfScope` gemerkt). Bis dahin gilt: fail-closed.

### 3.4 Paging / dünne Rows

Der Decorator arbeitet mit **virtuellen Offsets**: Aufrufer sehen eine Liste,
in der Hidden-Items nie existiert haben. Pro Query-Signatur werden
Checkpoints `sichtbarer Offset -> Server-Offset` gemerkt, sodass bestehende
Paging-Logik (Library-Grid, Favoriten, Home-`loadMore`, Collections) ohne
Änderung korrekt weiterpaged (keine Duplikate, keine Lücken).

Fehlen nach dem Filtern Items, wird **begrenzt** nachgeladen
(max. 3 Zusatz-Requests, wachsende Page-Größe, Cap 200), bis das Limit erreicht
ist, der Server nichts mehr liefert oder das Budget erschöpft ist.
`TotalRecordCount` wird um bereits gesehene Hidden-Items reduziert.
Ohne Hidden-Treffer: **0** Zusatz-Requests.

## 4. Visibility-Kontexte

| Kontext | Wer | Ergebnis |
|---|---|---|
| NORMAL | jede Item-Liste über den registrierten Client | Hidden immer entfernt – auch wenn ein Vault entsperrt ist |
| VAULT (explizit) | `VaultRepository` (nur Vault-UI) | ausschließlich Hidden-Inhalte des Vaults, serverseitig `Tags=…&ParentId=<lib>`, clientseitig exakt validiert |
| VAULT (verankert) | item-spezifische Calls (`getItem(id)`, `getSeasons(S)`, `getEpisodes(S)`, NextUp(seriesId), Similar, Extras, …) | nur erlaubt, wenn der Vault des Items **entsperrt UND betreten** ist |

Globale Listen (Home, Resume, Next Up, Latest, Suche, Library-Grids,
Screensaver, Channels) erhalten **nie** eine Ausnahme. Der Vault-Kontext ist
interner Session-State (In-Memory) – keine URL, kein Query-Parameter.
Die `/vault/...`-Routen sind zusätzlich per Router-Redirect an einen
entsperrten Vault gebunden.

## 5. Unlock-Flow

1. Normales Home, Fokus auf dem konfigurierten Trigger-Library-Tile.
2. OK/Select **≥ 2,5 s** halten (`SelectHoldTracker`, zentral in
   `key_event_utils.dart`, opt-in in `LockedFocusRow` nur für Trigger-Tiles).
   * kurzer Druck (< 0,5 s): Library öffnen wie bisher
   * 0,5–2,5 s: Kontextmenü beim Loslassen (nur Trigger-Tiles; alle anderen
     Tiles behalten das bisherige Verhalten). Menü-Taste unverändert.
3. PIN-Dialog (`PinEntryDialog`, Namespace `PinCodeUtil.vault`, gehasht + Salt,
   Lockout wie Kids-Mode).
4. Erfolg -> Session-Unlock im Speicher -> `/vault/<id>`.

Fallback für Touch/Desktop: Settings → Konto & Sicherheit → „Privater Bereich“
(PIN-geschützt) enthält „Öffnen“-Buttons.

Auto-Lock: App-Neustart (nur In-Memory), Logout, User-/Serverwechsel,
`AppLifecycleState.detached`, Hintergrund länger als Timeout, Inaktivität
(5/15/30/60 min, Default 15), „Beim Verlassen sperren“ (Default an).
Beim Lock: Vault-Routen werden verlassen (`go(home)`), Vault-Caches geleert,
globaler Backdrop zurückgesetzt.

## 6. Gates

* **Detail:** `getItem` eines Hidden-Items liefert im NORMAL-Kontext eine
  neutrale „nicht gefunden“-Antwort; das Detail-ViewModel zeigt den
  vorhandenen neutralen Blocked-Zustand („This isn't available“) – ohne Titel,
  ohne Artwork (Moonfin rendert vor dem Load ohnehin nur ein Skeleton).
  Deep Links (`moonfin://item`, `moonfin://play`), Watch-Next, Top Shelf,
  Push-Routen landen alle hier.
* **Playback:** `PlaybackManager.setContentRefusal` wird um das Hidden-Gate
  ergänzt (Queue-Filter synchron, Play-Refusal autoritativ). Mischqueues
  werden gefiltert; im betretenen Vault ist dessen Inhalt erlaubt.

## 7. Cache-Strategie

* Home-Row-Cache-Key enthält zusätzlich `hv:<token>` (Config-Fingerprint).
  Config-Änderung => neuer Key => kein Hydrate alter Rows. Zusätzlich werden
  hydrierte Rows gegen den aktuellen Index gefiltert (Index kann gewachsen sein).
* Recommendation-Caches (`RowDataSource.clearRecommendationCache`) und die
  Media Bar werden bei Config-Änderung bzw. wachsendem Hidden-Set gezielt
  neu geladen – keine globale Cache-Löschung.
* Vault-Daten liegen nur im `VaultRepository` (In-Memory, Key
  `vault:<id>:<fingerprint>:…`) und werden beim Lock verworfen.
* Index/Prüf-Cache sind pro Server+User+Fingerprint persistiert.

## 8. Performance

| Szenario | ohne Vault | mit Vault (warm) | mit Vault (kalt, erster Start) |
|---|---|---|---|
| Home-Load | unverändert | +0 Requests (Index persistiert); +1 Batch nur bei unbekannten Serien | +1 Request je Vault-Library (Index-Build) |
| Library öffnen (Anime/Serien) | unverändert | +0 (nur bei Hidden-Treffern begrenztes Nachladen) | wie warm |
| Next Up / Resume | unverändert | +0, max. +1 Batch für neue Serien | wie warm |
| Suche | unverändert | +0 (+ begrenztes Nachladen) | wie warm |
| Series-Lookups | – | 0 pro Episode (kein N+1) | 0 pro Episode |

Filter-Kosten pro Item: ein paar Hash-Lookups. Messwerte siehe §9.

## 9. Tests & Messungen

`test/custom/hidden_vault/` – u. a.:

* Tag-Matching (exakt, case-insensitive, kein Substring, `adult` vs.
  `adult animation`), Multi-Tag (ANY), Library-Scope.
* Episode-Vererbung, Batch-Resolution (20 Episoden / 3 Serien => 1 Request).
* Home (Latest/Resume/Next Up/Recommendations), Suche normal vs. Vault,
  Detail-Gate, Playback-Gate, Vault zeigt nur eigenen Scope,
  Unlock lässt Normal-Home gefiltert, Cache nach Config-Änderung.
* Virtuelles Paging (keine Duplikate/Lücken), begrenztes Overfetching.
* Secret Gesture (Tap / Kontextmenü / Extra-Long-Press).
* Request-Zählung (Fake-Server mit Bestandsgrößen wie im echten Setup).

Smoke-Test gegen den echten Server (read-only): `tool/hidden_vault_smoke.dart`.

## 10. Bekannte Grenzen

* Ein auf dem Server **nach** dem letzten Index-Refresh neu getaggtes Item wird
  über Tags/Batch erkannt; nur Items ohne `Fields`-Unterstützung (z. B.
  `Similar`, Playlist-Endpunkt) verlassen sich zwischen zwei Refreshes
  (≤ 10 min, plus beim App-Start) auf den Index.
* Collections (BoxSets) sind keiner Library zugeordnet: sie werden nur
  versteckt, wenn sie selbst einen konfigurierten Tag tragen; ihr Inhalt
  wird immer gefiltert.
* Seerr/TMDB-Rows zeigen externe Katalogdaten (keine lokalen Items) und
  werden nicht gefiltert; im Vault gibt es sie nicht.
* Bereits heruntergeladene Hidden-Inhalte werden in der Downloads-Liste
  gefiltert, bleiben aber auf dem Gerät.
* Secret Gesture ist für D-Pad/Tastatur umgesetzt; Touch nutzt den
  Settings-Fallback.

## 11. Upstream-Merge-Hinweise

Alle Upstream-Berührungen sind mit `// hidden-vault:` markiert
(`git grep "hidden-vault:"`). Bei Konflikten diese Zeilen wieder einsetzen:

| Datei | Hook |
|---|---|
| `lib/data/services/media_server_client_factory.dart` | Client wrappen / unwrappen |
| `lib/di/modules/server_module.dart` | aktiven Client wrappen |
| `lib/di/modules/playback_module.dart` | Content-Refusal kombinieren |
| `lib/di/modules/app_module.dart` | Vault-Session registrieren |
| `lib/ui/navigation/app_router.dart` | Vault-Routen + Redirect |
| `lib/data/viewmodels/item_detail_view_model.dart` | Hidden-Refusal -> blocked |
| `lib/ui/screens/home/home_view_model.dart` | Cache-Key-Token + Hydrate-Filter |
| `lib/ui/screens/home/home_screen.dart` | Trigger-Tiles (Hold-Geste) |
| `lib/ui/widgets/focus/locked_focus_row.dart` | opt-in Hold-Geste |
| `lib/util/focus/key_event_utils.dart` | `SelectHoldTracker` |
| `lib/util/pin_code_util.dart` | `PinCodeUtil.vault` |
| `lib/ui/screens/settings/panel/authentication_category_screen.dart` | Settings-Eintrag |

Strings des Vaults liegen in `lib/custom/hidden_vault/ui/vault_strings.dart`
(EN/DE) statt in den ARB-Dateien, damit Weblate-Commits nie mit dem Fork
kollidieren.
