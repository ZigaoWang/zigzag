<p align="center">
  <a href="https://zigzagbrowser.com"><img src="../../docs/brand/readme-hero.jpg" width="960" alt="Zigzag: Voelt geweldig. Weegt niets. De lichte browser voor Mac, gratis en open source. Een Zigzag-venster in Split View, Fonts In Use naast Grilli Type, met de navigatiekolom met spaces en vastgezette tabbladen."></a>
</p>

<div align="center">

<p align="center"><sub><a href="../../README.md">English</a> | <a href="README.zh-Hans.md">简体中文</a> | <a href="README.zh-Hant.md">繁體中文</a> | <a href="README.ja.md">日本語</a> | <a href="README.ko.md">한국어</a> | <a href="README.de.md">Deutsch</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.es.md">Español</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.ru.md">Русский</a> | Nederlands | <a href="README.pl.md">Polski</a> | <a href="README.tr.md">Türkçe</a></sub></p>

Deze pagina is een vertaling van README.md. Als ze van elkaar verschillen, is de Engelse versie leidend.

</div>

<p align="center">
  <a href="https://zigzagbrowser.com/download"><b>Download voor Mac</b></a><br>
  <sub>of <code>brew install --cask zigaowang/tap/zigzag</code></sub><br>
  <sub>Gratis en open source. macOS 15.4 of nieuwer.</sub>
</p>

<p align="center">
  Je tabbladen in een navigatiekolom, gegroepeerd in spaces. Een native Mac-app in Swift op WebKit,<br>
  ongeveer 35 MB na installatie, zonder account en zonder telemetrie.
</p>

## Waarom ik het heb gemaakt

Hoi, ik ben Zigao, een middelbare scholier in Shanghai. Ik gebruikte Arc elke dag. Toen The Browser Company aankondigde dat ze Arc op 22 december zouden stopzetten, wilde ik echt niet terug naar tabbladen bovenaan het scherm, en de alternatieven die ik probeerde waren Chromium-forks of browsers die rond AI zijn gebouwd. Dus maakte ik mijn eigen browser, en sindsdien gebruik ik die als mijn hoofdbrowser.

**Waarom WebKit en niet Chromium?** Ik ben eigenlijk begonnen met het forken van Helium. De broncode was ongeveer 100 GB groot en elke build duurde 3 tot 4 uur op mijn Mac, en dat hou ik in mijn eentje niet vol. WebKit zit al in macOS, is zuiniger met batterij en geheugen, en Apple levert de beveiligingsfixes mee met macOS-updates. Je krijgt nog steeds Chrome-extensies, rechtstreeks geïnstalleerd vanuit de Chrome Web Store.

**Waarom niet Zen of Orion?** Ik heb ze allebei geprobeerd voordat ik hieraan begon, en ze zijn goed. Zen draait op Firefox, gebruikt dus Firefox-extensies en voelt voor mij niet als een Mac-app. Orion zit er dichter bij, maar is niet open source. Ik wilde iets dat werkt als Arc, native aanvoelt, open source is en mijn Chrome-extensies draait.

## Overstappen vanuit Arc

**Je Arc gaat met je mee.** Kies Archief › Importeer vanuit andere browser…, kies Arc, en je spaces, vastgezette tabbladen, vastgezette mappen, favorieten, geschiedenis, wachtwoorden, aanmeldingen en extensies worden overgenomen. Je open tabbladen kunnen ook mee, inclusief Split View, en wachten met laden tot je erop klikt; laat Open tabbladen uitgevinkt om met een schone lei te beginnen. Als je spaces op meer dan één Arc-profiel staan, wordt elk Arc-profiel als een eigen Zigzag-profiel overgenomen.

**1Password werkt.** Installeer het vanuit de Chrome Web Store in Zigzag, zoals je dat in Arc zou doen. Het praat met de 1Password-app. Voeg Zigzag de eerste keer toe in 1Password › Instellingen › Browser. Bitwarden werkt ook.

**Het kan niet worden uitgezet.** Er is geen account, en Zigzag is niet afhankelijk van een server van mij. Het enige wat ik host zijn de updatefeed en een korte lijst met fixes voor het blokkeren van advertenties, en als die wegvallen, blijft Zigzag gewoon werken. [Privacy](#privacy) noemt alles waarmee Zigzag uit zichzelf verbinding maakt.

## Bekijk het

<p align="center">
  <img src="../../docs/spaces.gif" width="960" alt="Wisselen tussen drie spaces in Zigzag, elk met een eigen kleur en eigen tabbladen">
</p>

<table>
  <tr>
    <td width="50%"><img src="../../site/assets/clips/split.jpg" alt="Split View: Fonts In Use naast Grilli Type"><br><b>Split View.</b> Sleep een tabblad naar de pagina om het ernaast te openen, tot vier tegelijk.</td>
    <td width="50%"><img src="../../docs/all-tabs.jpg" alt="Alle tabbladen van drie spaces als kaarten"><br><b>Alle tabbladen tegelijk.</b> ⇧⌘\ toont elke space. Typ om te filteren.</td>
  </tr>
  <tr>
    <td width="50%"><img src="../../site/assets/win-peek.webp" alt="Een Wikipedia-artikel over typografie boven de pagina waarvanuit het is geopend"><br><b>Zigzag Mini.</b> Klik met ⇧ op een link om er een blik op te werpen zonder je plek kwijt te raken.</td>
    <td width="50%"><img src="../../site/assets/clips/reader.jpg" alt="Een essay van The Public Domain Review in Reader"><br><b>Reader.</b> Lange teksten, zonder de rommel eromheen.</td>
  </tr>
</table>

<p align="center"><sub>Meer, in beweging, op <a href="https://zigzagbrowser.com">zigzagbrowser.com</a>.</sub></p>

## Wat het doet

| | |
|---|---|
| **Spaces** | Elk met een eigen kleur, pictogram, vastgezette tabbladen en mappen. Veeg over de navigatiekolom, of duw het muiswiel opzij, om te wisselen. |
| **Favorieten** | Je meestgebruikte websites als tegels, boven elke space. Elk tabblad, vastgezet tabblad of elke favoriet kan een eigen emoji of symbool dragen. |
| **Profielen** | Houd werk en privé gescheiden. Elk profiel heeft eigen extensies, aanmeldingen, geschiedenis en favorieten, en elke space hoort bij één profiel. |
| **Websites in spaces** | Kies een space voor een website in Website-instellingen of Instellingen › Spaces, en de links ervan openen daar, waar ze ook vandaan komen: een andere app, ⌘T of een andere space, zoals bij Arc's Air Traffic Control. Paden kunnen ook naar hun eigen spaces gaan, zoals `github.com/org1` naar de ene en `github.com/org2` naar de andere. Een space met een eigen profiel werkt als een Firefox-container. |
| **Opdrachtbalk** | ⌘T of ⌘L. Vindt open tabbladen, geschiedenis en websites. Typ `you`, druk op Tab en je zoekt op YouTube. Sleep de balk ergens in het venster en hij opent daarna steeds daar. |
| **Tabbladgroepen** | Selecteer een paar tabbladen en kies Groepeer tabbladen, en ze worden een map in de navigatiekolom die opent en sluit, een andere naam krijgt en als geheel verplaatst. Sleep een tabblad naar rechts om het onder het tabblad erboven te zetten, en naar links om het er weer onderuit te halen. |
| **Livemappen** | Een vastgezette map die zichzelf vult vanuit een feed of een website, of vanuit GitHub: pull requests, reviewverzoeken, of de openstaande issues en pull requests in je repositories. Nieuwe pagina's krijgen een stip. |
| **Split View** | Tot vier tabbladen: sleep een tabblad naar de randen van de pagina voor een helft, of naar de hoeken voor een kwart. Sleep een pagina aan zijn balk om hem te verplaatsen, en zet een split vast om hem te bewaren. |
| **Vensters** | Sleep een tabblad naar een ander venster en het verhuist zoals het is, zonder opnieuw te laden. Zet Instellingen › Tabbladen › Vensters delen de tabbladen van een space aan en elk venster op een space toont dezelfde tabbladen, zoals in Arc. De navigatiekolom staat links of rechts. |
| **Web-apps** | Met Installeer als app wordt een website een eigen app, in je map Programma's, in het Dock en in ⌘Tab, met een werkbalk in de kleur van de website. |
| **Minispeler** | Verlaat een tabblad terwijl de video speelt en de video volgt je in een kleine speler. Pas het formaat aan vanaf elke rand en zet hem waar je wilt, ook buiten het venster boven andere apps. Zet hem uit via het menu als je hem liever niet hebt. Schakel je over naar een andere app, dan zweeft de video erboven in Beeld-in-beeld. |
| **Streaming** | Beschermde muziek en video spelen af zoals in Safari, via WebKit's FairPlay Streaming: de webspeler van Spotify werkt, en andere diensten die Safari ondersteunen ook. |
| **Speelt nu af** | Elk tabblad dat op de achtergrond geluid afspeelt krijgt onderaan de navigatiekolom een kaart, tot drie, om het te pauzeren of te dempen. |
| **Alle tabbladen** | ⇧⌘\ toont alle spaces tegelijk. Typ om te filteren, sleep een tabblad naar een andere space. |
| **Wis** | Sluit de tabbladen waar je van bent weggedreven en houdt de tabbladen waar je mee werkt. Wijs ernaar om te zien welke het zou sluiten. Een Split View blijft of gaat in zijn geheel. Maak ongedaan haalt ze terug. |
| **Zigzag Mini** | ⌃⌘N opent een klein venster voor één snelle pagina, en ⌘O verplaatst het naar je browservenster. Klik met ⇧ op een link, of kies Open link in Zigzag Mini, en hij opent in een Mini boven je venster; ⌘O zet hem in een tabblad naast het tabblad waarin je klikte, en Esc sluit hem. Links uit andere apps openen erin, zoals Little Arc (zet dat uit in Instellingen › Zigzag Mini), en Open in Zigzag Mini verplaatst een tabblad naar een Mini. |
| **Wachtwoorden** | In de sleutelhanger van je Mac, gesynchroniseerd via iCloud-sleutelhanger. Touch ID, een generator en een controle op zwakke en hergebruikte wachtwoorden. Passkeys werken. |
| **Donkere pagina's** | Lichte websites donker getekend door de engine van Dark Reader, met de fixes voor duizenden websites, zodat foto's er natuurlijk uitzien. Websites met een eigen donkere weergave houden die. Zuiver zwart als je het donkerder wilt. Overal aan of per website. |
| **Advertenties blokkeren** | Ingebouwd en aan: ongeveer 130.000 regels van EasyList, EasyPrivacy en EasyList China, gecompileerd tot WebKit-contentregellijsten, plus de filterlijsten van uBlock Origin, die zichzelf bijwerken. |
| **WebRTC** | Zet Bescherm IP-adres tegen WebRTC aan, en websites kunnen via WebRTC je echte IP-adres niet achterhalen terwijl je een proxy of vpn gebruikt. Gesprekken werken op de websites die je toestaat, en een website die WebRTC probeert terwijl het geblokkeerd is, meldt dat, met Sta toe voor deze website. |
| **Cookiebanners** | Voor je afgewezen, nooit geaccepteerd, met de Autoconsent-regels van DuckDuckGo. Laat ze overal met rust, of voor één website, als je liever zelf antwoordt. |
| **Website-instellingen** | Eén paneel per website: zoom, toestemmingen (camera, microfoon, locatie, meldingen, pop-ups, apps openen, scherm delen, WebRTC), elk ingesteld op Vraag, Sta toe of Blokkeer, JavaScript aan of uit, het certificaat, extensies, en schakelaars voor donkere pagina's, advertenties blokkeren en cookiebanners. Als een website om een van deze vraagt, doet hij dat op één kaart boven de pagina, voor deze keer of altijd, en een website waaraan je nee hebt gezegd, vraagt niet meer. |
| **Boosts** | Verberg element verbergt de delen van een website die je niet wilt, zoals een banner of een zijbalk, en Wijzig stijl geeft een website je eigen CSS. Beide staan in het menu ⋯ van Website-instellingen en blijven bij de website. |
| **Ontwikkelaarsmodus** | Voor de websites die je bouwt, om te beginnen `localhost`: de console met een foutenteller, Inspecteer element, apparaatformaten, licht en donker, printstijlen, JavaScript, afbeeldingen of stijlen uit, een andere user-agent, en een QR-code om de pagina op je telefoon te openen. |
| **Extensies** | Uit de Chrome Web Store, waar de eigen knop van de store Voeg toe aan Zigzag zegt. 1Password, Bitwarden, Dark Reader, Tampermonkey en de meeste populaire werken; zie hieronder wat niet werkt. |
| **Importeer** | Bladwijzers, geschiedenis, wachtwoorden, aanmeldingen en extensies uit Arc, Chrome, Safari, Dia, Edge, Brave, Vivaldi, Opera, Comet, Helium, Yandex, Whale, Chromium, Thorium, Firefox, Zen en Orion. |
| **Downloads** | Stuur bestanden van een bepaald type naar een eigen map, of open veilige, zoals pdf's, zodra ze zijn bewaard. Regels geven een link of een download door aan een app, een script of een downloadmanager zoals aria2, en vragen eerst om jouw toestemming. Zie [docs/download-rules.md](../../docs/download-rules.md). |
| **Automatisering** | AppleScript, Opdrachten en `osascript` kunnen tabbladen weergeven en openen en pagina's lezen, geschreven zoals Safari en Chrome ze accepteren. Zie [docs/automation.md](../../docs/automation.md). |
| **AI-apps** | Uit tot je het aanzet: AI-apps op je Mac kunnen je tabbladen gebruiken via MCP, nooit privévensters of wachtwoorden. Zie [docs/automation.md](../../docs/automation.md#ai-apps-mcp). |
| **Jouw gegevens** | Archief › Exporteer je gegevens… bewaart je bladwijzers als standaard HTML-bestand dat elke browser importeert, en een volledige Zigzag-reservekopie die je op een andere Mac kunt terugzetten. |
| **Talen** | Engels, vereenvoudigd Chinees, traditioneel Chinees, Japans, Koreaans, Duits, Frans, Italiaans, Spaans, Braziliaans Portugees, Russisch, Nederlands, Pools en Turks. |
| **En** | Reader, pdf-viewer, Handoff naar je iPhone, iPad of andere Mac, Opname van een gebied, een deel van de pagina of de hele pagina (⇧⌘2), vertalen op het apparaat, zoeken op pagina dat elke treffer markeert, een menu Geschiedenis met Recent gesloten en de laatste zeven dagen, een standaardzoom voor pagina's, een adresbalk boven de pagina als je die liever hebt, Beeld-in-beeld, privévensters, Webinspector. |

## Wat ontbreekt

Het is mijn dagelijkse browser, maar Zigzag is jong en je zult bugs vinden. Dingen die Arc-gebruikers zullen merken:

- Geen synchronisatie tussen Macs of naar de iPhone. Wachtwoorden synchroniseren via iCloud-sleutelhanger; spaces en tabbladen niet.
- Space-pictogrammen komen niet mee uit Arc; kies ze opnieuw in Zigzag. Space-kleuren worden overgenomen als de dichtstbijzijnde Zigzag-kleur.
- Geen Easels of Notes, en Boosts zijn alleen CSS (Verberg element en Wijzig stijl, geen scripts per website). Geen AI ingebouwd in de browser: AI-apps kunnen Zigzag alleen via MCP gebruiken als je dat aanzet.
- Een paar API's voor Chrome-extensies ontbreken nog: de API voor tabbladgroepen, debugger-instellingen, de eigen aanmelding van Chrome met een Google-account (`identity.getAuthToken`) en de oude request-blokkering webRequest. Proxy-extensies kunnen een vaste HTTP-, HTTPS- of SOCKS5-proxy instellen, maar geen PAC-script, dus de modus Proxy by Patterns van FoxyProxy werkt niet.
- EasyList en de andere ingebouwde blokkeerlijsten worden samen met Zigzag bijgewerkt, niet zelf; alleen de lijsten van uBlock Origin doen dat.
- Alleen macOS 15.4 of nieuwer.

## Hoe het is gebouwd

Zigzag is ongeveer 120.000 regels Swift 6 en AppKit rond `WKWebView`. Er is geen Chromium en geen Electron: de engine is het WebKit dat met macOS wordt meegeleverd, en daarom is de app klein en komen beveiligingsfixes van de engine met macOS-updates in plaats van van mij.

| Onderdeel | Hoe |
|---|---|
| **Pagina's** | Eén `WKWebView` per tabblad. Tabbladen die je een tijdje niet hebt gebruikt kunnen worden opgeschort: de webweergave wordt vrijgegeven en het tabblad bewaart zijn snapshot en status, en laadt opnieuw als je terugkomt. Privévensters gebruiken een niet-persistente gegevensopslag. |
| **Extensies** | De ondersteuning van WebKit voor webextensies (`WKWebExtensionController`, de reden voor het minimum van macOS 15.4). Zigzag downloadt het CRX3-pakket uit de Chrome Web Store, controleert de handtekeningen en laadt het. Chrome-API's die WebKit niet heeft (geschiedenis, bladwijzers, downloads, meldingen, zijpanelen, offscreen-pagina's, aanmelden via het web, tabbladgeluid, nieuwetabbladpagina's, gebruikersscripts, proxy's en meer) worden door Zigzag zelf beantwoord via een kleine brug, getoetst aan de eigen rechten van elke extensie. Een zoekmachine die een extensie meegeeft (`search_provider`) komt bij de keuzes in Instellingen te staan en wordt pas gebruikt als je hem kiest. Native messaging verbindt de hulp-apps van 1Password en andere extensies. |
| **Sandboxing** | Afbeeldingen en pdf's van websites worden gelezen in twee XPC-hulpprogramma's in een sandbox, `ZigzagImageDecoder` en `ZigzagPDFRenderer`, zonder netwerk en zonder bestandstoegang, zodat een misvormde afbeelding of pdf je wachtwoorden of profielen niet kan bereiken. De pdf-viewer tekent de pagina's die het hulpprogramma rendert; de app opent de pdf van een website nooit zelf. |
| **Beveiligde verbindingen** | Certificaatwaarschuwingen zeggen onder Details wat er mis is. Een website die alleen om beveiligde verbindingen vroeg, via zijn HSTS-header of op de preloadlijst van Chromium (meegeleverd, ongeveer 95.000 namen, alleen ter plekke gelezen als een waarschuwing het nodig heeft), krijgt geen Bezoek deze website toch, zoals in Safari en Chrome. Een website die om een certificaat vraagt om je te identificeren, krijgt de certificaten uit je sleutelhanger aangeboden die hij zou accepteren, zoals in Safari: voeg er een toe door het .p12-bestand in Sleutelhangertoegang te openen. |
| **Advertenties blokkeren** | EasyList, EasyPrivacy en EasyList China vooraf omgezet met SafariConverterLib naar contentregellijsten (`WKContentRuleListStore`), eenmaal gecompileerd en gecachet. De lijsten van uBlock Origin, gedownload zodra ze verlopen, worden vergeleken door de adblocker-engine van Ghostery in een eigen JavaScript-context, en elke pagina krijgt de scriptlets en verbergregels die zijn website nodig heeft zodra hij begint te laden. |
| **Donkere pagina's** | Het dynamische thema van Dark Reader en zijn fixes voor websites, meegeleverd, in een eigen scriptwereld. Pagina's krijgen eerst te horen dat het venster donker is, zodat een website met een eigen donker thema dat gebruikt en met rust wordt gelaten. |
| **Cookiebanners** | Autoconsent van DuckDuckGo en zijn regels, meegeleverd, in een eigen scriptwereld. |
| **Wachtwoorden** | Bewaard als sleutelhangeritems, zodat iCloud-sleutelhanger ze synchroniseert en Touch ID ze ontgrendelt. Passkeys lopen via de browser-passkey-entitlement van Apple. Automatisch invullen is een klein contentscript dat alleen velden invult die je kunt zien. |
| **Importeer** | Leest de eigen bestanden van elke browser: `StorableSidebar.json` van Arc, de bladwijzers en SQLite-geschiedenis van Chromium, `Bookmarks.plist` van Safari, `places.sqlite` van Firefox, `favourites.plist` en `history` van Orion. Chromium-wachtwoorden worden ontsleuteld met de sleutel uit het sleutelhangeritem van die browser, nadat macOS het je heeft gevraagd. |
| **Jouw gegevens** | Spaces, vastgezette tabbladen en favorieten in `Library.json`, profielen in `Profiles.json`, open tabbladen in `Session.json`, geschiedenis in SQLite (één bestand per profiel), alles in `~/Library/Application Support/Zigzag`. Schrijfacties worden gebundeld en zijn atomair, en een bestand dat niet kan worden gelezen wordt apart gezet, nooit overschreven. |
| **Reader** | Readability van Mozilla, uitgevoerd in de pagina, getoond in de eigen typografie van Zigzag. |
| **Web-apps** | Een als app geïnstalleerde website is een kleine eigen app in `~/Applications/Zigzag Apps` die elke start doorgeeft aan Zigzag, zodat de pagina in Zigzag draait met je aanmeldingen, extensies en blokkering. |
| **Updates** | Sparkle 2, met EdDSA-ondertekende updates van zigzagbrowser.com, op een stabiele of een bèta-feed. Releases zijn ondertekend met Developer ID en genotariseerd. |

De broncode is georganiseerd per functie: `Sidebar`, `Tabs`, `Web`, `Extensions`, `Passwords`, `Import`, `Profiles`, `CommandBar`, `Desk` (alle tabbladen tegelijk), `WebApps`, `Developer`, `MCP` (AI-apps), `Settings`, `Window` en `Design` (de eigen getekende regelaars en designtokens van Zigzag). Meer dan 2.000 tests dekken importeren, wachtwoorden, extensies, adresverwerking, geschiedenis, AI-apps en de beveiligingsfixes.

## Privacy

Geen account, geen analytics, geen telemetrie. Niets over hoe je browset wordt naar mij gestuurd. Dit zijn de enige verbindingen die Zigzag uit zichzelf maakt, afgezien van de pagina's die je opent:

- **Updates.** Om de paar uur, en nadat je Mac uit de slaap komt, leest Zigzag de updatefeed op zigzagbrowser.com. Het verzoek vermeldt de versie van Zigzag en verder niets; er wordt geen systeemprofiel verstuurd. Een nieuwe versie wordt ook daarvandaan gedownload.
- **Zoeksuggesties.** Terwijl je in de adresbalk typt, gaat de tekst zonder cookies naar je zoekmachine voor suggesties. Google, DuckDuckGo, Brave, Bing, Kagi en Ecosia bieden ze aan; bij elke andere zoekmachine wordt niets verstuurd. Zet ze uit in Instellingen › Zoek.
- **Websitepictogrammen.** Pictogrammen komen van de websites zelf, ook voor vastgezette tabbladen, favorieten en geïmporteerde bladwijzers die je nog niet hebt geopend.
- **Filterlijsten.** Bij het starten en daarna zodra ze verlopen, om de paar uur tot eens per dag, downloadt Zigzag de filterlijsten van uBlock Origin van de eigen adressen van uBlock Origin (GitHub Pages, Cloudflare Pages of jsDelivr) en de scriptlets ervan van de CDN van Ghostery. Ook downloadt het Zigzags eigen korte lijst met websitefixes van zigzagbrowser.com. De verzoeken bevatten geen cookies en niets over jou of je browsen.
- **Extensies.** Een extensie installeren downloadt hem uit de Chrome Web Store. Bij het starten, hooguit eens per dag, vraagt Zigzag de store of je extensies updates hebben, waarbij hun ID's en versies naar Google gaan.
- **Configuratie.** De welkomstschermen tonen een paar websitepictogrammen van de pictogramdienst van Google en laden de voorpagina van Wikipedia als voorbeeld.

Vertalen gebeurt op je Mac, met de Vertaling van Apple op het apparaat. Waarschuwingen voor frauduleuze websites zijn die van WebKit zelf, dezelfde als die van Safari. Wachtwoorden blijven in de sleutelhanger van je Mac en synchroniseren alleen via je eigen iCloud-sleutelhanger. Help › Meld een probleem schrijft een rapport dat je eerst kunt lezen, en er wordt niets verstuurd tenzij jij het verstuurt. De lijst Wachtwoorden van de Mac houdt een klein logboek van zijn stappen bij in `~/Library/Logs/Zigzag/passwords.log`, nooit een aanmelding of een website, en het blijft op je Mac. Je Zigzag-kaart wordt op je Mac gemaakt van de naam van je account en de dag waarop Zigzag voor het eerst draaide, en de afbeelding bevat alleen wat de kaart toont.

## Installeren

Download de dmg van [zigzagbrowser.com](https://zigzagbrowser.com/download), open hem en sleep Zigzag naar Programma's. Of, met Homebrew:

    brew install --cask zigaowang/tap/zigzag

Updates worden vanzelf geïnstalleerd. Wat er in elke versie is veranderd, staat in de [release-opmerkingen](https://zigzagbrowser.com/release-notes) en [CHANGELOG.md](../../CHANGELOG.md).

## Feedback

- **Bugs en ideeën:** [open een issue](https://github.com/ZigaoWang/zigzag/issues/new/choose), of kies Help › Stuur feedback… in de app. Voor een bug schrijft Help › Meld een probleem… een rapport dat je kunt lezen voordat je het verstuurt.
- **E-mail:** a@zigao.wang
- **Beveiligingsproblemen:** zie [SECURITY.md](../../SECURITY.md). Plaats ze alsjeblieft niet in openbare issues.

## Zelf bouwen vanuit de broncode

Vereisten: macOS 15.4 of nieuwer, Xcode 27 of nieuwer en [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
git clone https://github.com/ZigaoWang/zigzag.git
cd zigzag
xcodegen generate
open Zigzag.xcodeproj
```

Draai het schema **Zigzag**. Debug-builds draaien als een aparte app, “Zigzag Dev”, met eigen gegevens, zodat ze nooit aan je dagelijkse Zigzag komen.

De ondertekening is ingesteld voor mijn team. Om op jouw Mac te bouwen, wijzig je twee dingen in `project.yml` en voer je `xcodegen generate` opnieuw uit:

- `DEVELOPMENT_TEAM`: je eigen team-ID (Xcode › Settings › Accounts toont het).
- De Debug-`PRODUCT_BUNDLE_IDENTIFIER`: een eigen ID, zoals `com.yourname.zigzag.dev`, omdat `wang.zigao.zigzag.dev` op mijn team is geregistreerd.

Draai de tests:

```sh
xcodebuild test -project Zigzag.xcodeproj -scheme Zigzag
```

## Bijdragen

Bijdragen zijn welkom. Lees [CONTRIBUTING.md](../../CONTRIBUTING.md) voor hoe het project wordt gebouwd, getest en opgemaakt.

## Licentie

De code van Zigzag valt onder de [Apache License, Version 2.0](../../LICENSE). Gebruik het, wijzig het, fork het en lever het uit, commercieel of niet.

De naam “Zigzag”, het app-pictogram en het logo vallen niet onder de licentie: het zijn handelsmerken, alle rechten voorbehouden. Een fork heeft een eigen naam en pictogram nodig. Zie [TRADEMARKS.md](../../TRADEMARKS.md) en [NOTICE](../../NOTICE). Werk van derden dat Zigzag gebruikt staat in [THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md).

## Dankwoord

Dank aan de [LINUX DO](https://linux.do)-community voor het vroeg uitproberen van Zigzag en het delen van hun feedback.

<p align="center">
  <a href="https://linux.do"><img src="https://shorturl.at/ggSqS" alt="LINUX DO" /></a>
</p>
