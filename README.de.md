<p align="center">
  <a href="https://zigzagbrowser.com"><img src="docs/brand/readme-hero.jpg" width="960" alt="Zigzag: Fühlt sich großartig an. Wiegt nichts. Der leichte Browser für den Mac, kostenlos und Open Source. Ein Zigzag-Fenster in der Split View, Fonts In Use neben Grilli Type, mit der Seitenleiste aus Spaces und fixierten Tabs."></a>
</p>

<div align="center">

[English](README.md) | [简体中文](README.zh-Hans.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | Deutsch | [Français](README.fr.md) | [Italiano](README.it.md) | [Español](README.es.md) | [Português (Brasil)](README.pt-BR.md) | [Русский](README.ru.md) | [Nederlands](README.nl.md) | [Polski](README.pl.md) | [Türkçe](README.tr.md)

Diese Seite ist eine Übersetzung der README.md. Weichen sie voneinander ab, gilt die englische Version.

</div>

<p align="center">
  <a href="https://zigzagbrowser.com/download"><b>Für den Mac laden</b></a><br>
  <sub>oder <code>brew install --cask zigaowang/tap/zigzag</code></sub><br>
  <sub>Kostenlos und Open Source. Ab macOS 15.4.</sub>
</p>

<p align="center">
  Deine Tabs in einer Seitenleiste, in Spaces gruppiert. Eine native Mac-App in Swift auf WebKit,<br>
  installiert etwa 35 MB groß, ohne Account und ohne Telemetrie.
</p>

## Warum ich es gebaut habe

Hi, ich bin Zigao, Oberschüler in Shanghai. Ich habe jeden Tag Arc benutzt. Als The Browser Company ankündigte, Arc am
22. Dezember einzustellen, wollte ich auf keinen Fall zurück zu Tabs am oberen Rand, und die Alternativen, die ich
ausprobiert habe, waren entweder Chromium-Forks oder Browser, die um KI herum gebaut sind. Also habe ich mir meinen
eigenen gebaut, und seitdem ist er mein Hauptbrowser.

**Warum WebKit und nicht Chromium?** Angefangen habe ich tatsächlich mit einem Fork von Helium. Der Quellcode war etwa
100 GB groß, und jeder Build dauerte auf meinem Mac 3 bis 4 Stunden, das kann ich allein nicht durchhalten. WebKit ist
schon in macOS enthalten, schont Akku und Arbeitsspeicher mehr, und Apple liefert die Sicherheitskorrekturen mit den
macOS-Updates aus. Chrome-Erweiterungen bekommst du trotzdem, direkt aus dem Chrome Web Store installiert.

**Warum nicht Zen oder Orion?** Beide habe ich vor diesem Projekt ausprobiert, und sie sind gut. Zen basiert auf
Firefox, nutzt also Firefox-Erweiterungen und fühlt sich für mich nicht wie eine Mac-App an. Orion kommt näher heran,
ist aber nicht Open Source. Ich wollte etwas, das wie Arc funktioniert, sich nativ anfühlt, Open Source ist und meine
Chrome-Erweiterungen ausführt.

## Von Arc umsteigen

**Dein Arc zieht mit um.** „Ablage“ › „Aus anderem Browser importieren …“, Arc wählen, und deine Spaces, fixierten Tabs, fixierten Ordner, Favoriten,
dein Verlauf, deine Passwörter, Anmeldungen und Erweiterungen werden übernommen. Auch deine offenen Tabs können mitkommen, samt Split Views, und laden
erst, wenn du sie anklickst; lass „Offene Tabs“ deaktiviert, um sauber zu starten. Liegen deine Spaces in mehr als einem Arc-Profil,
wird jedes Arc-Profil als eigenes Zigzag-Profil übernommen.

**1Password funktioniert.** Installiere es in Zigzag aus dem Chrome Web Store, so wie du es in Arc tun würdest. Es spricht mit der
1Password-App. Beim ersten Mal fügst du Zigzag unter „1Password“ › „Einstellungen“ › „Browser“ hinzu. Bitwarden funktioniert ebenfalls.

**Es lässt sich nicht abschalten.** Es gibt keinen Account, und Zigzag hängt von keinem Server von mir ab. Das Einzige,
was ich hoste, sind der Update-Feed und eine kurze Liste mit Korrekturen für den Werbeblocker. Fielen sie weg, würde Zigzag weiter funktionieren.
Unter [Datenschutz](#datenschutz) steht alles, womit Zigzag sich von selbst verbindet.

## Ansehen

<p align="center">
  <img src="docs/spaces.gif" width="960" alt="Wechsel zwischen drei Spaces in Zigzag, jeder mit eigener Farbe und eigenen Tabs">
</p>

<table>
  <tr>
    <td width="50%"><img src="site/assets/clips/split.jpg" alt="Split View: Fonts In Use neben Grilli Type"><br><b>Split View.</b> Zieh einen Tab auf die Seite, um ihn daneben zu öffnen, bis zu vier gleichzeitig.</td>
    <td width="50%"><img src="docs/all-tabs.jpg" alt="Alle Tabs aus drei Spaces als Karten dargestellt"><br><b>Alle Tabs auf einmal.</b> ⇧⌘\ zeigt jeden Space. Tippe, um zu filtern.</td>
  </tr>
  <tr>
    <td width="50%"><img src="site/assets/win-peek.webp" alt="Ein Wikipedia-Artikel über Typografie über der Seite, von der aus er geöffnet wurde"><br><b>Zigzag Mini.</b> Klicke bei gedrückter Umschalttaste auf einen Link, um einen Blick darauf zu werfen, ohne den Faden zu verlieren.</td>
    <td width="50%"><img src="site/assets/clips/reader.jpg" alt="Ein Essay der Public Domain Review im Reader"><br><b>Reader.</b> Lange Texte, ohne Ablenkung.</td>
  </tr>
</table>

<p align="center"><sub>Mehr, in Bewegung, auf <a href="https://zigzagbrowser.com">zigzagbrowser.com</a>.</sub></p>

## Was es kann

| | |
|---|---|
| **Spaces** | Jeder mit eigener Farbe, eigenem Symbol, eigenen fixierten Tabs und Ordnern. Zum Wechseln auf der Seitenleiste wischen oder das Mausrad seitwärts anstupsen. |
| **Favoriten** | Deine meistgenutzten Websites als Kacheln, über jedem Space. Jeder Tab, fixierte Tab und jeder Favorit kann sein eigenes Emoji oder Symbol tragen. |
| **Profile** | Halte Arbeit und Privates getrennt. Jedes Profil hat eigene Erweiterungen, Anmeldungen, einen eigenen Verlauf und eigene Favoriten, und jeder Space gehört zu einem Profil. |
| **Websites in Spaces** | Wähle in den Website-Einstellungen oder unter „Einstellungen“ › „Spaces“ einen Space für eine Website, und ihre Links öffnen sich dort, woher sie auch kommen: aus einer anderen App, per ⌘T oder aus einem anderen Space, wie bei Arcs Air Traffic Control. Auch Pfade können in eigene Spaces gehen, etwa `github.com/org1` in den einen und `github.com/org2` in den anderen. Ein Space mit eigenem Profil funktioniert wie ein Firefox-Container. |
| **Befehlsleiste** | ⌘T oder ⌘L. Findet offene Tabs, den Verlauf und Websites. Tippe `you`, drücke den Tabulator, und du suchst auf YouTube. Zieh die Leiste an eine beliebige Stelle im Fenster, und sie öffnet sich fortan dort. |
| **Tabgruppen** | Wähle ein paar Tabs und „Tabs gruppieren“, und sie werden zu einem Ordner in der Seitenleiste, der sich als Ganzes öffnen und schließen, umbenennen und bewegen lässt. Zieh einen Tab nach rechts, um ihn unter dem Tab darüber einzuordnen, und nach links, um ihn wieder herauszunehmen. |
| **Live-Ordner** | Ein fixierter Ordner, der sich selbst aus einem Feed, von einer Website oder von GitHub füllt: Pull Requests, Review-Anfragen oder die offenen Issues und Pull Requests in deinen Repositorys. Neue Seiten kommen mit einem Punkt. |
| **Split View** | Bis zu vier Tabs: Zieh einen Tab an die Ränder der Seite für eine Hälfte oder in die Ecken für ein Viertel. Zieh eine Seite an ihrer Leiste, um sie zu bewegen, und fixiere eine Split View, um sie zu behalten. |
| **Fenster** | Zieh einen Tab in ein anderes Fenster, und er zieht um, wie er ist, ohne neu zu laden. Schalte „Fenster teilen die Tabs eines Space“ unter „Einstellungen“ › „Tabs“ ein, und jedes Fenster eines Space listet dieselben Tabs, wie in Arc. Die Seitenleiste sitzt links oder rechts. |
| **Web-Apps** | „Als App installieren“ macht aus einer Website eine eigene App, in deinem Ordner „Programme“, im Dock und im ⌘Tab, mit einer Symbolleiste in der Farbe der Website. |
| **Mini-Player** | Verlasse einen Tab, während sein Video läuft, und das Video folgt dir in einem kleinen Player. Ändere die Größe an jeder Kante und platziere ihn überall, sogar außerhalb des Fensters über anderen Apps. Schalte ihn über sein Menü aus, wenn du ihn nicht möchtest. Wechselst du in eine andere App, schwebt das Video darüber als Bild-in-Bild. |
| **Streaming** | Geschützte Musik und Videos spielen wie in Safari, über WebKits FairPlay Streaming: Der Web-Player von Spotify funktioniert, ebenso andere Dienste, die Safari unterstützen. |
| **Jetzt läuft** | Jeder Tab, der im Hintergrund Ton abspielt, bekommt unten in der Seitenleiste eine Karte, bis zu drei, zum Pausieren oder Stummschalten. |
| **Alle Tabs** | ⇧⌘\ zeigt alle Spaces auf einmal. Tippe, um zu filtern, und zieh einen Tab in einen anderen Space. |
| **Aufräumen** | Schließt die Tabs, von denen du dich entfernt hast, und behält die, mit denen du arbeitest. Zeig darauf, um zu sehen, welche es schließen würde. Eine Split View bleibt oder geht als Ganzes. „Widerrufen“ holt sie zurück. |
| **Zigzag Mini** | ⌃⌘N öffnet ein kleines Fenster für eine kurze Seite, und ⌘O bewegt es in dein Browserfenster. Klicke bei gedrückter Umschalttaste auf einen Link oder wähle „Link in Zigzag Mini öffnen“, und er öffnet sich in einem Mini über deinem Fenster; ⌘O legt ihn in einen Tab neben dem, in dem du geklickt hast, und Esc schließt ihn. Links aus anderen Apps öffnen sich darin, wie bei Little Arc (das schaltest du unter „Einstellungen“ › „Zigzag Mini“ aus), und „In Zigzag Mini öffnen“ bewegt einen Tab in eins. |
| **Passwörter** | Im Schlüsselbund deines Macs, per iCloud-Schlüsselbund synchronisiert. Touch ID, ein Generator und eine Prüfung auf schwache und mehrfach verwendete Passwörter. Passkeys funktionieren. |
| **Dunkle Seiten** | Helle Websites, von der Engine von Dark Reader dunkel gezeichnet, mit dessen Korrekturen für Tausende Websites, damit Fotos natürlich bleiben. Websites mit eigenem dunklem Look behalten ihn. Reines Schwarz, wenn du es dunkler magst. Überall oder pro Website. |
| **Werbeblocker** | Eingebaut und aktiv: etwa 130.000 Regeln aus EasyList, EasyPrivacy und EasyList China, in WebKit-Content-Rule-Listen kompiliert, dazu die Filterlisten von uBlock Origin, die sich selbst aktualisieren. |
| **WebRTC** | Schalte „IP-Adresse vor WebRTC schützen“ ein, und Websites erfahren über WebRTC nicht deine echte IP-Adresse, solange du einen Proxy oder ein VPN nutzt. Anrufe funktionieren auf den Websites, die du erlaubst, und eine Website, die WebRTC versucht, während es blockiert ist, sagt es dir, mit „Für diese Website erlauben“. |
| **Cookie-Banner** | Für dich abgelehnt, nie akzeptiert, mit den Autoconsent-Regeln von DuckDuckGo. Lass sie überall oder für eine Website in Ruhe, wenn du lieber selbst antwortest. |
| **Website-Einstellungen** | Ein Bereich pro Website: Zoom, Berechtigungen (Kamera, Mikrofon, Standort, Mitteilungen, Pop-ups, Öffnen von Apps, Bildschirmfreigabe, WebRTC), jede auf „Fragen“, „Erlauben“ oder „Blockieren“ gestellt, JavaScript ein oder aus, das Zertifikat, Erweiterungen und Schalter für dunkle Seiten, Werbeblocker und Cookie-Banner. Fragt eine Website nach einer davon, fragt sie auf einer einzigen Karte über der Seite, für dieses Mal oder immer, und eine Website, der du abgesagt hast, fragt nicht mehr. |
| **Boosts** | „Element ausblenden“ blendet die Teile einer Website aus, die du nicht willst, etwa ein Banner oder eine Seitenleiste, und „Stil bearbeiten“ gibt einer Website eigenes CSS. Beides findest du im Menü ⋯ der Website-Einstellungen, und es bleibt bei der Website. |
| **Entwicklermodus** | Für die Websites, die du baust, zunächst `localhost`: die Konsole mit Fehlerzähler, „Element untersuchen“, Gerätegrößen, hell und dunkel, Druckstile, JavaScript, Bilder oder Stile aus, ein anderer User-Agent und ein QR-Code, um die Seite auf dem iPhone zu öffnen. |
| **Erweiterungen** | Aus dem Chrome Web Store, wo der Button des Stores „Zu Zigzag hinzufügen“ heißt. 1Password, Bitwarden, Dark Reader, Tampermonkey und die meisten beliebten funktionieren; was nicht geht, steht weiter unten. |
| **Import** | Lesezeichen, Verlauf, Passwörter, Anmeldungen und Erweiterungen aus Arc, Chrome, Safari, Dia, Edge, Brave, Vivaldi, Opera, Comet, Helium, Yandex, Whale, Chromium, Thorium, Firefox, Zen und Orion. |
| **Downloads** | Schicke Dateien eines Typs in einen eigenen Ordner oder öffne sichere wie PDFs, sobald sie gesichert sind. Regeln übergeben einen Link oder einen Download an eine App, ein Skript oder einen Download-Manager wie aria2, nachdem sie dich gefragt haben. Siehe [docs/download-rules.md](docs/download-rules.md). |
| **Automation** | AppleScript, Kurzbefehle und `osascript` können Tabs auflisten und öffnen und Seiten lesen, in der Form, wie Safari und Chrome sie annehmen. Siehe [docs/automation.md](docs/automation.md). |
| **KI-Apps** | Aus, bis du es einschaltest: KI-Apps auf deinem Mac können deine Tabs über MCP nutzen, nie private Fenster oder Passwörter. Siehe [docs/automation.md](docs/automation.md#ai-apps-mcp). |
| **Deine Daten** | „Ablage“ › „Deine Daten exportieren …“ sichert deine Lesezeichen als Standard-HTML-Datei, die jeder Browser importiert, und ein vollständiges Zigzag-Backup, das du auf einem anderen Mac wiederherstellen kannst. |
| **Sprachen** | Englisch, Vereinfachtes Chinesisch, Traditionelles Chinesisch, Japanisch, Koreanisch, Deutsch, Französisch, Italienisch, Spanisch, Brasilianisches Portugiesisch, Russisch, Niederländisch, Polnisch und Türkisch. |
| **Und** | Reader, PDF-Viewer, Handoff auf dein iPhone, iPad oder einen anderen Mac, Bildschirmfoto eines Bereichs, eines Teils der Seite oder der ganzen Seite (⇧⌘2), Übersetzung auf dem Gerät, „Auf Seite suchen“ mit Markierung jedes Treffers, ein Menü „Verlauf“ mit „Zuletzt geschlossen“ und den letzten sieben Tagen, ein Standard-Seitenzoom, eine Adressleiste über der Seite, wenn du eine haben möchtest, Bild-in-Bild, private Fenster, Web-Inspektor. |

## Was fehlt

Es ist mein Alltagsbrowser, aber Zigzag ist jung, und du wirst Fehler finden. Was Arc-Nutzern auffallen wird:

- Kein Sync zwischen Macs oder aufs iPhone. Passwörter synchronisieren über den iCloud-Schlüsselbund; Spaces und Tabs nicht.
- Space-Symbole kommen nicht aus Arc mit; wähle sie in Zigzag neu aus. Space-Farben werden als nächstliegende Zigzag-Farbe übernommen.
- Keine Easels oder Notes, und Boosts sind nur CSS („Element ausblenden“ und „Stil bearbeiten“, keine Skripte pro Website). Keine in den Browser eingebaute KI: KI-Apps können Zigzag nur über MCP nutzen, wenn du es einschaltest.
- Ein paar Chrome-Erweiterungs-APIs fehlen noch: die Tabgruppen-API, Debugger-Einstellungen, Chromes eigene Anmeldung mit dem Google-Account (`identity.getAuthToken`) und das alte Request-Blocking per webRequest. Proxy-Erweiterungen können einen festen HTTP-, HTTPS- oder SOCKS5-Proxy setzen, aber kein PAC-Skript, daher funktioniert der Modus „Proxy by Patterns“ von FoxyProxy nicht.
- EasyList und die anderen eingebauten Blocklisten werden mit Zigzag aktualisiert, nicht von selbst; nur die Listen von uBlock Origin tun das.
- Nur ab macOS 15.4.

## Wie es gebaut ist

Zigzag besteht aus etwa 120.000 Zeilen Swift 6 und AppKit rund um `WKWebView`. Es gibt kein Chromium und kein Electron: Die
Engine ist das WebKit, das mit macOS kommt, weshalb die App klein ist und Sicherheitskorrekturen der Engine
mit macOS-Updates eintreffen statt von mir.

| Teil | Wie |
|---|---|
| **Seiten** | Ein `WKWebView` pro Tab. Tabs, die du länger nicht benutzt hast, können ruhen gelassen werden: Die Web View wird freigegeben, und der Tab behält seinen Schnappschuss und Zustand, dann lädt er neu, wenn du zurückkommst. Private Fenster nutzen einen nicht persistenten Datenspeicher. |
| **Erweiterungen** | WebKits Unterstützung für Web-Erweiterungen (`WKWebExtensionController`, der Grund für das Minimum macOS 15.4). Zigzag lädt das CRX3-Paket aus dem Chrome Web Store, prüft seine Signaturen und lädt es. Chrome-APIs, die WebKit nicht hat (Verlauf, Lesezeichen, Downloads, Mitteilungen, Seitenbereiche, Offscreen-Seiten, Web-Anmeldung, Tab-Audio, Seiten für neue Tabs, Benutzerskripte, Proxys und mehr), beantwortet Zigzag selbst über eine kleine Brücke, geprüft gegen die eigenen Berechtigungen jeder Erweiterung. Eine Suchmaschine, die eine Erweiterung mitbringt (`search_provider`), kommt in die Auswahl unter „Einstellungen“ und wird erst verwendet, wenn du sie wählst. Native Messaging verbindet die Helfer-Apps von 1Password und anderen Erweiterungen. |
| **Sandboxing** | Bilder und PDFs von Websites werden in zwei Sandbox-XPC-Helfern gelesen, `ZigzagImageDecoder` und `ZigzagPDFRenderer`, ohne Netzwerk und ohne Dateizugriff, sodass ein fehlerhaftes Bild oder PDF nicht an deine Passwörter oder Profile kommt. Der PDF-Viewer zeichnet die Seiten, die der Helfer rendert; die App öffnet das PDF einer Website nie selbst. |
| **Sichere Verbindungen** | Zertifikatswarnungen sagen unter „Details“, was nicht stimmt. Eine Website, die per HSTS-Header oder auf Chromiums Preload-Liste (mitgeliefert, etwa 95.000 Namen, nur gelesen, wenn eine Warnung es braucht) ausschließlich sichere Verbindungen verlangt hat, bekommt kein „Trotzdem besuchen“, wie in Safari und Chrome. Einer Website, die ein Zertifikat zu deiner Identifizierung verlangt, werden die Zertifikate in deinem Schlüsselbund angeboten, die sie akzeptieren würde, wie in Safari: Füge eines hinzu, indem du seine .p12 in der Schlüsselbundverwaltung öffnest. |
| **Werbeblocker** | EasyList, EasyPrivacy und EasyList China, vorab mit SafariConverterLib in Content-Rule-Listen (`WKContentRuleListStore`) umgewandelt, einmal kompiliert und gecacht. Die Listen von uBlock Origin, geladen, wenn sie ablaufen, werden von der Adblocker-Engine von Ghostery in einem eigenen JavaScript-Kontext abgeglichen, und jede Seite bekommt die Scriptlets und Ausblendregeln, die ihre Website braucht, sobald sie zu laden beginnt. |
| **Dunkle Seiten** | Das dynamische Theme von Dark Reader und seine Website-Korrekturen, mitgeliefert, in einer eigenen Script World. Seiten erfahren zuerst, dass das Fenster dunkel ist, sodass eine Website mit eigenem dunklem Theme es nutzt und in Ruhe gelassen wird. |
| **Cookie-Banner** | Autoconsent von DuckDuckGo und seine Regeln, mitgeliefert, in einer eigenen Script World. |
| **Passwörter** | Als Schlüsselbundeinträge gesichert, sodass der iCloud-Schlüsselbund sie synchronisiert und Touch ID sie entsperrt. Passkeys laufen über Apples Entitlement für Browser-Passkeys. Das automatische Ausfüllen ist ein kleines Content-Skript, das nur Felder ausfüllt, die du sehen kannst. |
| **Import** | Liest die eigenen Dateien jedes Browsers: Arcs `StorableSidebar.json`, Chromiums Lesezeichen und SQLite-Verlauf, Safaris `Bookmarks.plist`, Firefox' `places.sqlite`, Orions `favourites.plist` und `history`. Chromium-Passwörter werden mit dem Schlüssel aus dem Schlüsselbundeintrag dieses Browsers entschlüsselt, nachdem macOS dich gefragt hat. |
| **Deine Daten** | Spaces, fixierte Tabs und Favoriten in `Library.json`, Profile in `Profiles.json`, offene Tabs in `Session.json`, der Verlauf in SQLite (eine Datei pro Profil), alles unter `~/Library/Application Support/Zigzag`. Schreibvorgänge sind verzögert und atomar, und eine Datei, die sich nicht lesen lässt, wird beiseitegelegt, nie überschrieben. |
| **Reader** | Mozillas Readability, in der Seite ausgeführt, in Zigzags eigener Typografie dargestellt. |
| **Web-Apps** | Eine als App installierte Website ist eine kleine eigene App in `~/Applications/Zigzag Apps`, die jeden Start an Zigzag übergibt, sodass die Seite in Zigzag läuft, mit deinen Anmeldungen, Erweiterungen und dem Blockieren. |
| **Updates** | Sparkle 2, mit EdDSA-signierten Updates von zigzagbrowser.com, auf einem stabilen oder einem Beta-Feed. Releases sind mit Developer ID signiert und notarisiert. |

Der Quellcode ist nach Funktionen gegliedert: `Sidebar`, `Tabs`, `Web`, `Extensions`, `Passwords`, `Import`, `Profiles`,
`CommandBar`, `Desk` (alle Tabs auf einmal), `WebApps`, `Developer`, `MCP` (KI-Apps), `Settings`, `Window` und
`Design` (Zigzags eigene gezeichnete Bedienelemente und Design-Tokens). Über 2.000 Tests decken Import, Passwörter, Erweiterungen,
Adressverarbeitung, Verlauf, KI-Apps und die Sicherheitskorrekturen ab.

## Datenschutz

Kein Account, keine Analyse, keine Telemetrie. Nichts darüber, wie du surfst, wird an mich gesendet. Das sind die einzigen
Verbindungen, die Zigzag von selbst aufbaut, abgesehen von den Seiten, die du öffnest:

- **Updates.** Alle paar Stunden und nachdem dein Mac aufgewacht ist, liest Zigzag den Update-Feed auf zigzagbrowser.com. Die
  Anfrage nennt die Version von Zigzag und sonst nichts; kein Systemprofil wird gesendet. Eine neue Version wird ebenfalls von dort geladen.
- **Suchvorschläge.** Während du in der Adressleiste tippst, geht der Text für Vorschläge an deine Suchmaschine,
  ohne Cookies. Google, DuckDuckGo, Brave, Bing, Kagi und Ecosia bieten sie an; bei jeder anderen Suchmaschine wird nichts
  gesendet. Schalte sie unter „Einstellungen“ › „Suche“ aus.
- **Website-Symbole.** Symbole kommen von jeder Website selbst, auch für fixierte Tabs, Favoriten und importierte Lesezeichen, die du
  noch nicht geöffnet hast.
- **Filterlisten.** Beim Start und dann, wenn sie ablaufen, alle paar Stunden bis einmal am Tag, lädt Zigzag die Filterlisten von uBlock
  Origin von den eigenen Adressen von uBlock Origin (GitHub Pages, Cloudflare Pages oder jsDelivr) und dessen
  Scriptlets vom CDN von Ghostery. Außerdem lädt es Zigzags eigene kurze Liste mit Website-Korrekturen von zigzagbrowser.com.
  Die Anfragen tragen keine Cookies und nichts über dich oder dein Surfen.
- **Erweiterungen.** Beim Installieren wird eine aus dem Chrome Web Store geladen. Beim Start, höchstens einmal am Tag, fragt Zigzag
  den Store, ob es für deine Erweiterungen Updates gibt, wodurch ihre IDs und Versionen an Google gehen.
- **Konfiguration.** Die Willkommensbildschirme zeigen ein paar Website-Symbole aus dem Symboldienst von Google und laden die Startseite von Wikipedia
  als Vorschau.

Die Übersetzung läuft auf deinem Mac, mit der Übersetzung von Apple auf dem Gerät. Warnungen vor betrügerischen Websites stammen von WebKit selbst,
dieselben wie in Safari. Passwörter bleiben im Schlüsselbund deines Macs und werden nur über deinen eigenen iCloud-Schlüsselbund synchronisiert.
„Hilfe“ › „Problem melden …“ schreibt einen Bericht, den du vorher lesen kannst, und nichts wird gesendet, solange du ihn nicht sendest.
Die Passwortliste des Macs führt ein kleines Protokoll ihrer Schritte in `~/Library/Logs/Zigzag/passwords.log`, nie eine Anmeldung oder
eine Website, und es bleibt auf deinem Mac. Deine Zigzag-Karte wird auf deinem Mac aus dem Namen deines Accounts und dem Tag erstellt, an dem Zigzag
zum ersten Mal lief, und ihr Bild enthält nur, was die Karte zeigt.

## Installation

Lade das DMG von [zigzagbrowser.com](https://zigzagbrowser.com/download), öffne es und zieh Zigzag in den Ordner
„Programme“. Oder mit Homebrew:

    brew install --cask zigaowang/tap/zigzag

Updates installieren sich von selbst. Was sich in jeder Version geändert hat, steht in den
[Release Notes](https://zigzagbrowser.com/release-notes) und in der [CHANGELOG.md](CHANGELOG.md).

## Feedback

- **Fehler und Ideen:** [Eröffne ein Issue](https://github.com/ZigaoWang/zigzag/issues/new/choose) oder wähle in der App „Hilfe“ › „Feedback senden …“. Bei einem Fehler schreibt „Hilfe“ › „Problem melden …“ einen Bericht, den du vor dem Senden lesen kannst.
- **E-Mail:** a@zigao.wang
- **Sicherheitsprobleme:** siehe [SECURITY.md](SECURITY.md). Poste sie bitte nicht in öffentlichen Issues.

## Aus dem Quellcode bauen

Voraussetzungen: macOS 15.4 oder neuer, Xcode 27 oder neuer und [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
git clone https://github.com/ZigaoWang/zigzag.git
cd zigzag
xcodegen generate
open Zigzag.xcodeproj
```

Führe das Schema **Zigzag** aus. Debug-Builds laufen als eigene App, „Zigzag Dev“, mit eigenen Daten, sodass sie dein
alltägliches Zigzag nie anrühren.

Die Signierung ist für mein Team eingerichtet. Um auf deinem Mac zu bauen, ändere zwei Dinge in `project.yml` und führe
`xcodegen generate` erneut aus:

- `DEVELOPMENT_TEAM`: deine eigene Team-ID („Xcode“ › „Einstellungen“ › „Accounts“ zeigt sie).
- Der Debug-`PRODUCT_BUNDLE_IDENTIFIER`: eine eigene, etwa `com.yourname.zigzag.dev`, da
  `wang.zigao.zigzag.dev` für mein Team registriert ist.

Die Tests ausführen:

```sh
xcodebuild test -project Zigzag.xcodeproj -scheme Zigzag
```

## Mitwirken

Beiträge sind willkommen. Lies [CONTRIBUTING.md](CONTRIBUTING.md), wie das Projekt gebaut, getestet und
gestaltet wird.

## Lizenz

Der Code von Zigzag steht unter der [Apache License, Version 2.0](LICENSE). Nutze ihn, ändere ihn, forke ihn und liefere
ihn aus, kommerziell oder nicht.

Der Name „Zigzag“, das App-Symbol und das Logo fallen nicht unter die Lizenz: Sie sind Marken, alle Rechte
vorbehalten. Ein Fork braucht einen eigenen Namen und ein eigenes Symbol. Siehe [TRADEMARKS.md](TRADEMARKS.md) und [NOTICE](NOTICE).
Drittanbieter-Software, die Zigzag nutzt, ist in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) aufgeführt.

## Danksagung

Dank an die Community von [LINUX DO](https://linux.do), die Zigzag früh ausprobiert und ihr Feedback geteilt hat.

<p align="center">
  <a href="https://linux.do"><img src="https://shorturl.at/ggSqS" alt="LINUX DO" /></a>
</p>
