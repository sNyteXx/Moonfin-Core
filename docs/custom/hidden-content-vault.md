# Hidden Content Vault (Custom-Erweiterung dieses Forks)

> Fork-spezifische Erweiterung, bewusst so geschnitten, dass sie sich bei
> Upstream-Merges über wenige, markierte Hook-Zeilen pflegen lässt
> (`git grep "hidden-vault:"`).

## 1. Ziel

Beliebige Jellyfin-Serien/-Filme anhand **frei konfigurierbarer Jellyfin-Tags**
vollständig aus der normalen Moonfin-Oberfläche entfernen und nur in einem
PIN-geschützten, unsichtbar erreichbaren *Vault* zeigen.

* Tags sind **nicht** hart verdrahtet (`ecchi`, `private`, … sind nur Beispiele;
  ohne Konfiguration ist das Feature inaktiv und jeder Call geht unverändert
  durch).
* Matching ist **exakt und case-insensitive**: `Ecchi == ecchi`, aber
  `adult != adult animation`, `hidden != hidden gem`, `ecchi != super-ecchi`.
  Normalisierung nur für Vergleiche (trim, Whitespace-Läufe → ein Leerzeichen,
  lowercase); Anzeige behält die Server-Schreibweise.
* Mehrere Tags pro Library: **Hide if ANY tag matches**.
* Tags werden **pro Library** eines Vaults gespeichert, Identität ist die
  **Library-ID** (Umbenennen ändert nichts). Eine Library gehört zu höchstens
  einem Vault.
* Beliebig viele Vault-Gruppen über *eine* Implementierung, z. B.
  „Anime“ = Anime + Filme (Anime), „Serien/Filme“ = Serien + Filme.
* Zwei Visibility-Kontexte: **NORMAL** (Hidden immer raus) und **VAULT**
  (gezielt die Hidden-Inhalte eines Vaults). **Unlock schaltet nichts global
  frei.**

## 2. Einrichtung (Bedienung)

1. Einstellungen → *Konto & Sicherheit* → Abschnitt *Privatsphäre & Sicherheit*
   → **„Privater Bereich“**. Beim ersten Mal wird eine eigene 4-stellige PIN
   gesetzt (nicht Login-/Kids-Mode-PIN), danach wird sie jedes Mal abgefragt.
2. *Bereich hinzufügen* → Name, Bibliotheken (z. B. Anime + Filme (Anime)),
   pro Bibliothek *Versteckte Tags* (Mehrfachauswahl aus den tatsächlich
   vorhandenen Tags der Library, Filterfeld, plus *Tag manuell hinzufügen*),
   *Geöffnet über* = Trigger-Kachel (z. B. Anime).
3. *Speichern* – der Hidden-Index wird gebaut (1 Request je Library), alle
   normalen Screens laden gefiltert neu.
4. Öffnen: im Startbildschirm Fokus auf die Trigger-Kachel, **OK ≥ 2,5 s
   halten** → PIN → Vault. Fallback (Touch/Desktop): im selben Settings-Screen
   *Öffnen: <Name>*.

## 3. Architektur

Alles Custom liegt unter `lib/custom/hidden_vault/`, Tests unter
`test/custom/hidden_vault/`, das Smoke-Tool unter `tool/`.

```
lib/custom/hidden_vault/
  hidden_vault.dart                 Fassade: alle Hooks für Upstream-Code
  model/
    tag_match.dart                  normalizeTag(), extractTags() (Tags / Emby TagItems)
    vault_config.dart               VaultConfig / VaultDefinition / VaultLibrary / VaultSettings
    hidden_tag_policy.dart          Library-ID -> (Vault, Tag-Set); exaktes Matching
  data/
    vault_store.dart                VaultScope (Server+User), Storage-Keys
    hidden_content_index.dart       Hidden-Index + Builder + kompakter Codec
    item_tag_resolver.dart          gebündelte Tag-Lookups (Coalescing, In-Flight-Dedupe)
    hidden_content_service.dart     pro Server+User: Config, Policy, Index, Verdicts
    hidden_content_registry.dart    Scope -> Service (auch im Background-Isolate)
    visibility_items_api.dart       ItemsApi-Decorator = zentraler Leak-Schutz
    visibility_media_server_client.dart  Client-Wrapper (Items/UserLibrary/InstantMix)
    virtual_pager.dart              virtuelles Paging + begrenztes Nachladen
    vault_repository.dart           VAULT-Kontext-Queries
  session/vault_session.dart        In-Memory-Unlock, Timeout, Lock-on-leave, Auto-Lock
  gate/hidden_content_gate.dart     Playback-Gate (+ Detail via Refusal)
  ui/                               Vault-Home/-Grid/-Suche, Settings, Zugriff, Strings
```

### 3.1 Warum ein `ItemsApi`-Decorator

Die Analyse ergab: der vorhandene Blocked-Ratings-Filter (`withoutBlockedItems`)
wird an rund einem Dutzend Stellen umgangen (Screensaver, Shuffle,
Genre-Artwork, Android Auto/CarPlay, Detail-Next-Up, Buch-Serien, Downloads,
Server-Remote-Play …). Für „kein Leak“ reicht Filtern an Einzelstellen nicht.

Moonfin hat die passende Naht bereits: `MediaServerClient` ist ein Interface
und `ConnectivityAwareMediaServerClient` wickelt den echten Client schon ein.
Der Vault fügt eine Schicht hinzu:

```
VisibilityMediaServerClient              NEU: filtert Item-Listen (NORMAL-Kontext)
  └─ ConnectivityAwareMediaServerClient  Upstream: online/offline Routing
       └─ Jellyfin/Emby-Client           Upstream
```

Gewrappt wird in `MediaServerClientFactory._createClient` und
`setActiveServerClient`, also für **jeden** Client: aktiver Client,
Multi-Server, Playback-Resolver und die Background-Engines (Watch Next,
Launcher-Channels, Auto-Download). Damit laufen alle ~100 Item-Abfragen
(Home, Continue Watching, Next Up, Latest, Recently Released, Empfehlungen,
Moonfin Recommends, Media Bar, Suche, Library-Grids, Genres, Studios,
Favoriten, Collections, Similar, Filmografie, Screensaver, Android-TV-Channels
und Watch Next, Top Shelf, Shuffle, Android Auto, Playback-Queues,
Server-Remote-Play) durch dieselbe Prüfung – auch künftige Upstream-Features.
Offline-Listen aus dem Download-Katalog werden ebenso gefiltert.

`withoutBlockedItems` / `BlockedContentGate` bleiben unverändert; an den Gates
werden beide Regeln kombiniert. Ein großer „ContentVisibilityPolicy“-Umbau
wurde bewusst vermieden (Merge-Freundlichkeit).

## 4. Datenfluss

### 4.1 Hidden-Index

Jellyfin-DTOs enthalten **keine** Library-ID. Ein reiner Tag-Vergleich könnte
die Scope-Regel („Anime-Tags betreffen die Serien-Library nicht“) daher nicht
einhalten. Der Service baut stattdessen pro konfigurierter Library **eine**
serverseitige Query:

```
GET /Users/{u}/Items?ParentId=<libraryId>&Recursive=true&Tags=<t1>|<t2>
    &Fields=Tags&SortBy=SortName&ImageTypeLimit=0&EnableTotalRecordCount=true&Limit=1000
```

Verifiziert im Jellyfin-Quellcode (master, Commit `305a964`, 2026-10-01;
`BaseItemRepository.TranslateQuery.cs`, `ItemsController.cs`,
`StringExtensions.GetCleanValue`):

* `Tags` ist pipe-getrennt und hat **OR-Semantik**
  (`ItemValues.Any(CleanValue ∈ tags)`) → eine Query je Library genügt.
* Der Server vergleicht `GetCleanValue` (Diakritika weg, lowercase,
  Satzzeichen → Leerzeichen). Das ist lockerer als exakt (z. B. `Ecchi!`
  matcht `ecchi`) → der Client **validiert jedes Ergebnis exakt** über das
  `Tags`-Feld und verwirft Abweichungen.
* `Ids` + `ParentId` + `Recursive` werden über TopParentIds geschnitten (AND).
  Wird nicht benötigt, nur dokumentiert.

Direkt gegen Tower konnte aus der Cloud-Umgebung nicht getestet werden →
`tool/hidden_vault_smoke.dart` (§9) prüft genau diese Punkte read-only am
echten Server.

Ergebnis: `Map<ItemId, (vaultId, libraryId, type)>` (bei ~150 Ecchi-Serien
wenige KB), persistiert pro Server+User mit Config-Fingerprint. App-Start:
persistierter Index sofort nutzbar, Hintergrund-Refresh wenn älter als
10 min. Nur wenn gar kein Index existiert, wird einmalig auf den Build
gewartet (schlägt er fehl: tag-basierter Fallback, der eher zu viel als zu
wenig versteckt).

### 4.2 Normal-Filter (synchron, O(1) pro Item)

```
hidden(item) =
     item.Id / SeriesId / SeasonId / AlbumId ∈ Index    (Episoden erben von der Serie)
  ∨  BoxSet/Playlist mit eigenem passendem Tag            (keiner Library zugeordnet)
  ∨  Verdacht, solange unbestätigt (4.3)
```

### 4.3 Aktualität ohne N+1

* **Eigene Tags** kommen im normalen Request mit: der Decorator hängt `Tags`
  an vorhandene `Fields` (bzw. an die Detail-Felder bei `getItem`) – nur wenn
  ein Vault aktiv ist. Kein separater Request.
* Matcht ein Tag, das Item ist aber nicht im Index → **Verdacht**: bleibt
  versteckt, ein Index-Rebuild (Single-Flight) entscheidet exakt. Liegt es
  außerhalb jeder Vault-Library, wird es als `outOfScope` gemerkt und
  persistiert – kostet also einmal.
* **Episoden/Staffeln**, deren Serie weder im Index noch im Prüf-Cache ist,
  werden pro Response **gesammelt** und mit **einem** Batch
  `getItems(ids: [...], fields: Tags)` aufgelöst (Chunk 100, Coalescing im
  selben Event-Loop-Tick, In-Flight-Dedupe, Cache 12 h, persistiert).
  20 Episoden aus 3 Serien → **1** Request (Test).
* `SeriesId`-Lookups pro Episode gibt es nicht (`getItem` wird nie pro Episode
  gerufen; Test zählt 0).

### 4.4 Paging / dünne Rows

Der Decorator arbeitet mit **virtuellen Offsets**: Aufrufer sehen eine Liste,
in der Hidden-Items nie existierten. Pro Query-Signatur werden Checkpoints
`sichtbarer Offset → Server-Offset` gemerkt, sodass bestehende Paging-Logik
(Library-Grid, Favoriten, Home-`loadMore`, Collections) **ohne Änderung**
korrekt weiterpaged – ohne Duplikate oder Lücken (Test über 60 Items mit
jedem dritten versteckt).

Begrenztes adaptives Nachladen: fehlen nach dem Filtern Items, liest der
Decorator weiter, bis die Page voll ist bzw. eine „volle Row“
(min(Limit, 24)) erreicht ist, der Server nichts mehr liefert oder das Budget
(max. 3 Zusatz-Requests, wachsende Page-Größe, Cap 200) erschöpft ist.
`TotalRecordCount` wird um bereits gesehene Hidden-Items reduziert.
Ohne Hidden-Treffer: **0** Zusatz-Requests.

## 5. Visibility-Kontexte

| Kontext | Wer | Ergebnis |
|---|---|---|
| NORMAL | jede Item-Liste über die App-Clients | Hidden immer entfernt – auch bei entsperrtem/geöffnetem Vault |
| VAULT (explizit) | `VaultRepository` (nur Vault-Screens) | ausschließlich Hidden-Inhalte des Vaults; Library-Listen serverseitig `ParentId=<lib>&Tags=…` + exakte Validierung; Resume/Next Up/Episodensuche über den Index |
| VAULT (item-spezifisch) | `getItem(id)`, `getSeasons(S)`, `getEpisodes(S)`, NextUp(`seriesId`), `getItems(ids)`, Similar, Extras, InstantMix | Inhalte eines Vaults nur, wenn genau dieser Vault **entsperrt UND betreten** ist |

Globale Listen erhalten **nie** eine Ausnahme. Der Vault-Kontext ist reiner
In-Memory-Session-State; Routen (`/vault/<id>`) sind über den Router-Redirect
an diesen State gebunden. Ein Deep Link / eine Push-Route auf `/vault/...`
landet im gesperrten Zustand auf Home; Kids Mode sperrt den Vault komplett.

## 6. Unlock-Flow & Session

1. Trigger-Kachel fokussiert, OK halten. Zentral in
   `key_event_utils.dart` (`SelectHoldGesture`, timerbasiert) und opt-in in
   `LockedFocusRow` (`holdSelectEnabled`/`onHoldSelect`), nur für Kacheln mit
   vollständig eingerichtetem Vault (Regeln + Trigger + PIN):
   * < 0,5 s: Library öffnen wie bisher
   * 0,5–2,5 s: Kontextmenü **beim Loslassen** (nur Trigger-Kacheln)
   * ≥ 2,5 s: PIN-Dialog (keine sichtbare UI vorher)
   * Menü-Taste: Kontextmenü unverändert; alle anderen Kacheln unverändert
     (500-ms-Menü wie bisher).
2. `PinEntryDialog` mit `PinCodeUtil.vault(store, scope)`: eigener Namespace,
   pro Server+User, SHA-256 mit Scope-Salt, Lockout wie Kids Mode
   (5 freie Versuche, dann 30 s steigend bis 15 min).
3. Erfolg → `VaultSessionController.unlock()` (nur Speicher) → `/vault/<id>`.

Auto-Lock: App-Neustart/Kill (nichts persistiert), Logout, User-/Serverwechsel
(`UserRepository.currentUserStream`), `AppLifecycleState.detached`,
Hintergrund länger als der Timeout, Inaktivität (5/15/30/60 min, Default 15;
laufende Vault-Wiedergabe zählt als Aktivität), *Beim Verlassen sperren*
(Default an). Beim Lock: alle Vault-Routen und darüberliegende Detail/Player-
Seiten werden per `go(home)` verlassen, das Vault-Repository verworfen, der
globale Backdrop geleert.

## 7. Gates

* **Detail:** `getItem` eines Hidden-Items außerhalb des geöffneten Vaults
  liefert eine neutrale 404-artige `HiddenContentRefusal`; das Detail-
  ViewModel zeigt den bestehenden neutralen Blocked-Zustand („This isn't
  available“) – Moonfin rendert vor dem Load nur ein Skeleton, d. h. weder
  Titel noch Artwork erscheinen. Gilt für Deep Links (`moonfin://item`,
  `moonfin://play`), Watch Next, Top Shelf, Push-Routen, Remote-Control.
* **Playback:** `PlaybackManager.setContentRefusal` kombiniert Hidden-Gate und
  Blocked-Ratings-Gate (Queue-Filter synchron, Play-Refusal autoritativ).
  Mischqueues werden gefiltert; im betretenen Vault ist dessen Inhalt erlaubt,
  der andere Vault bleibt zu.

## 8. Cache-Strategie

* Home-Row-Cache-Key enthält `hv:<Config-Fingerprint>`; hydrierte Rows werden
  zusätzlich gegen den aktuellen Index gefiltert (Index kann gewachsen sein).
* Bei Regeländerung / wachsendem Hidden-Set genau **ein** Neuladen der
  normalen Screens: Recommendation-Caches leeren, Media Bar `force`, Home über
  `homeRefreshBus` – keine globale Cache-Löschung.
* Der Fingerprint hängt nur an Vault-IDs, Library-IDs und normalisierten Tags;
  Namen, Trigger und Session-Einstellungen invalidieren nichts.
* Vault-Daten nur im `VaultRepository` der aktuellen Vault-Sitzung
  (In-Memory, pro Visit); kein Disk-Cache für Vault-Inhalte.
* Persistiert pro Server+User: Config, Index, Prüf-Cache (`outOfScope`,
  Tag-Checks). Nie ein Unlock-Zustand (Test prüft die Keys).
* Downloads-Listen filtern Hidden-Inhalte (Dateien bleiben auf dem Gerät).

## 9. Tests & Messungen

```
flutter test test/custom/hidden_vault/     # 82 Tests
flutter test                               # gesamte Suite
```

Abgedeckt u. a.: exaktes Matching (`ecchi` vs `Ecchi`/`ECCHI`, nicht
`ecchi comedy`/`super-ecchi`; `adult` vs `adult animation`; `hidden` vs
`hidden gem`), Multi-Tag (ANY), Library-Scope, Episode-Vererbung,
Batch-Resolution, Home (Latest/Resume/Next Up/Recommendations/Similar), Suche
normal vs. Vault, Detail-Gate, Playback-Gate inkl. Mischqueue, Vault zeigt nur
eigenen Scope, Unlock lässt Normal-Home gefiltert, Cache nach
Config-Änderung, virtuelles Paging, Read-Ahead-Budget, Secret Gesture
(Tap/Menü/Hold, andere Kacheln unverändert), Session (Timeout, Lock on leave,
Kontowechsel, Lifecycle), PIN-Namespace.

Request-Zählung mit Bestand in echter Größe (Anime 793 Serien / 23.548
Episoden, Filme (Anime) 417, Serien 795 / 18.998, Filme 2.843; ~150 Serien
„Ecchi“), Home über die echte `RowDataSource`
(`test/custom/hidden_vault/performance_test.dart`):

| Szenario | Requests | davon Tag-Lookups |
|---|---|---|
| Home, Vault aus | 8 | 0 |
| Index-Build (Speichern / erster Start) | 2 (1 je Library) | 0 |
| Home, Vault an, erster Start | 13 | 2 |
| Home, Vault an, warm | 11 | 0 |
| Home, Vault an, nächster App-Start | 11 | 0 |
| Anime öffnen (3 Pages à 48) | 3 | 0 |
| Serien öffnen (3 Pages à 48) | 3 | 0 |
| Next Up | 2 | 0 |
| Suche | 1 | 0 |

Die +3 im warmen Home sind das gewünschte begrenzte Auffüllen von Rows, die
durch das Filtern Items verloren haben (Resume, Next Up, Anime-Filme-Latest).
Kein vollständiges Vorladen von Libraries/Episoden, keine Requests pro
Episode. Filterkosten: Hash-Lookups pro Item; die Rows rendern sofort aus
dem persistierten Index.

Smoke-Test gegen den echten Server (nur GET, ändert nichts):

```
dart run tool/hidden_vault_smoke.dart --server http://tower:8096 \
  --token <Access-Token> --user <User-ID> \
  --rule 0c419071-40d8-02bb-5843-0fed7e2cd79e=ecchi \
  --rule b72a4b60-0ac4-8fda-a566-40e70b65fd05=ecchi
```

Gibt pro Library aus: Treffer je Tag, OR-Semantik-Check bei mehreren Tags,
Kosten des Index-Builds, durch exaktes Matching verworfene Server-Treffer,
gleiche Tags außerhalb der Library (bleiben sichtbar) und wie viele Next-Up-
Episoden über ihre Serie gefiltert würden. Die IDs oben sind nur die
Entwicklungsreferenz und stehen nirgends im Code.

Android: Der komplette Dart-Code wurde im Release-Modus (Produkt, TFA) für
`android-arm64` und `android-arm` AOT kompiliert (`libapp.so`). Das
Gradle-Packaging zur APK braucht das Android SDK von `dl.google.com`, das in
der Cloud-Umgebung gesperrt war → auf ubuntudev mit `./build-android.sh`
bauen.

## 10. Bekannte Grenzen

* Ein nach dem letzten Index-Refresh neu getaggtes Item wird über eigene Tags
  bzw. den Serien-Batch sofort erkannt; nur Endpunkte ohne `Fields`
  (Similar, Playlist-Items) verlassen sich bis zum nächsten Refresh
  (≤ 10 min, plus App-Start) auf den Index.
* Collections (BoxSets) sitzen in keiner Library: sie verschwinden nur mit
  eigenem konfiguriertem Tag; ihr Inhalt wird immer gefiltert.
* Seerr/TMDB/IMDb-Rows zeigen externe Katalogdaten (keine lokalen Items) und
  werden nicht gefiltert; im Vault gibt es sie nicht.
* Downloads: Hidden-Inhalte verschwinden aus den Listen, Dateien bleiben. Ein
  im Vault eingerichteter Auto-Download zeigt seine Download-Benachrichtigung.
* Jellyfin selbst (Dashboard „Now playing“, andere Clients) ist außerhalb des
  Scopes.
* Secret Gesture ist für D-Pad/Tastatur umgesetzt; Touch nutzt den
  Settings-Fallback.
* Admin-Metadaten-Editor öffnet Hidden-Items nur aus dem Vault heraus.

## 11. Upstream-Merge-Hinweise

Alle Upstream-Berührungen sind mit `// hidden-vault:` markiert. Bei Konflikten
diese Zeilen wieder einsetzen:

| Datei | Hook |
|---|---|
| `lib/data/services/media_server_client_factory.dart` | Client wrappen / unwrappen |
| `lib/di/modules/server_module.dart` | aktiven Client wrappen |
| `lib/di/modules/playback_module.dart` | Content-Refusal kombinieren |
| `lib/di/modules/app_module.dart` | `HiddenVault.initForeground()` |
| `lib/ui/navigation/app_router.dart` | Vault-Routen + Redirect |
| `lib/data/viewmodels/item_detail_view_model.dart` | Refusal → blocked |
| `lib/ui/screens/home/home_view_model.dart` | Cache-Key-Token + Hydrate-Filter |
| `lib/ui/screens/home/home_screen.dart` | Trigger-Kacheln (Hold-Geste) |
| `lib/ui/widgets/focus/locked_focus_row.dart` | opt-in Hold-Geste |
| `lib/util/focus/key_event_utils.dart` | `SelectHoldGesture` |
| `lib/util/pin_code_util.dart` | `PinCodeUtil.vault` |
| `lib/data/providers/offline_providers.dart` | Downloads-Listen filtern |
| `lib/ui/screens/settings/settings_side_panel.dart` + `panel/authentication_category_screen.dart` | Settings-Eintrag |

Strings liegen in `lib/custom/hidden_vault/ui/vault_strings.dart` (EN/DE)
statt in den ARB-Dateien, damit Weblate-Commits nie mit dem Fork kollidieren.
