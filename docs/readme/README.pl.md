<p align="center">
  <a href="https://zigzagbrowser.com"><img src="../../docs/brand/readme-hero.jpg" width="960" alt="Zigzag: świetnie się go używa, nic nie waży. Lekka przeglądarka dla Maca, darmowa i open source. Okno Zigzag w Split View: Fonts In Use obok Grilli Type, z paskiem bocznym przestrzeni i przypiętych kart."></a>
</p>

<div align="center">

<p align="center"><sub><a href="../../README.md">English</a> | <a href="README.zh-Hans.md">简体中文</a> | <a href="README.zh-Hant.md">繁體中文</a> | <a href="README.ja.md">日本語</a> | <a href="README.ko.md">한국어</a> | <a href="README.de.md">Deutsch</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.es.md">Español</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.ru.md">Русский</a> | <a href="README.nl.md">Nederlands</a> | Polski | <a href="README.tr.md">Türkçe</a></sub></p>

Ta strona jest tłumaczeniem pliku README.md; jeśli się różnią, obowiązuje wersja angielska.

</div>

<p align="center">
  <a href="https://zigzagbrowser.com/download"><b>Pobierz na Maca</b></a><br>
  <sub>lub <code>brew install --cask zigaowang/tap/zigzag</code></sub><br>
  <sub>Darmowa i open source. macOS 15.4 lub nowszy.</sub>
</p>

<p align="center">
  Twoje karty na pasku bocznym, pogrupowane w przestrzenie. Natywna aplikacja na Maca napisana w Swift na WebKit,<br>
  po instalacji zajmuje około 35 MB, bez konta i bez telemetrii.
</p>

## Dlaczego go stworzyłem

Cześć, jestem Zigao, uczeń liceum z Szanghaju. Codziennie korzystałem z Arc. Kiedy The Browser Company ogłosiło, że wyłącza Arc 22 grudnia, naprawdę nie chciałem wracać do kart na górze okna, a alternatywy, które wypróbowałem, były albo forkami Chromium, albo przeglądarkami zbudowanymi wokół AI. Zrobiłem więc własną i od tamtej pory używam jej jako głównej przeglądarki.

**Dlaczego WebKit, a nie Chromium?** Zacząłem od forka Helium. Kod źródłowy miał około 100 GB, a każda kompilacja trwała na moim Macu 3 do 4 godzin, czego sam nie byłbym w stanie utrzymać. WebKit jest już częścią macOS, mniej obciąża baterię i pamięć, a Apple dostarcza jego poprawki bezpieczeństwa wraz z aktualizacjami macOS. Nadal możesz używać rozszerzeń do Chrome, instalowanych prosto z Chrome Web Store.

**Dlaczego nie Zen ani Orion?** Wypróbowałem obie przed rozpoczęciem pracy i są dobre. Zen działa na Firefoksie, więc korzysta z rozszerzeń do Firefoksa i moim zdaniem nie wygląda jak aplikacja na Maca. Orion jest bliżej, ale nie ma otwartego kodu. Chciałem przeglądarki, która działa jak Arc, jest natywna, ma otwarty kod i uruchamia moje rozszerzenia do Chrome.

## Jeśli przychodzisz z Arc

**Twój Arc przenosi się razem z tobą.** „Plik” › „Importuj z innej przeglądarki…”, wybierz Arc i przeniosą się twoje przestrzenie, przypięte karty, przypięte foldery, ulubione, historia, hasła, logowania i rozszerzenia. Mogą przyjść też twoje otwarte karty, razem z widokami Split View, i poczekają z wczytaniem, aż je klikniesz; odznacz „Otwarte karty”, aby zacząć od zera. Jeśli twoje przestrzenie są w więcej niż jednym profilu Arc, każdy profil Arc staje się osobnym profilem w Zigzag.

**1Password działa.** Zainstaluj go z Chrome Web Store w Zigzag, tak jak w Arc. Łączy się z aplikacją 1Password. Za pierwszym razem dodaj Zigzag w 1Password › Ustawienia › Przeglądarka. Bitwarden też działa.

**Nie da się go wyłączyć.** Nie ma konta, a Zigzag nie zależy od mojego serwera. Hostuję tylko kanał aktualizacji i krótką listę poprawek blokowania reklam, a gdyby zniknęły, Zigzag nadal by działał. Sekcja [Prywatność](#prywatność) wymienia wszystko, z czym Zigzag łączy się samodzielnie.

## Zobacz

<p align="center">
  <img src="../../docs/spaces.gif" width="960" alt="Przełączanie między trzema przestrzeniami w Zigzag, z których każda ma własny kolor i karty">
</p>

<table>
  <tr>
    <td width="50%"><img src="../../site/assets/clips/split.jpg" alt="Split View: Fonts In Use obok Grilli Type"><br><b>Split View.</b> Przeciągnij kartę na stronę, aby otworzyć ją obok, do czterech naraz.</td>
    <td width="50%"><img src="../../docs/all-tabs.jpg" alt="Wszystkie karty z trzech przestrzeni pokazane jako karty-kafelki"><br><b>Wszystkie karty naraz.</b> ⇧⌘\ pokazuje każdą przestrzeń. Wpisz tekst, aby filtrować.</td>
  </tr>
  <tr>
    <td width="50%"><img src="../../site/assets/win-peek.webp" alt="Artykuł z Wikipedii o typografii nad stroną, z której został otwarty"><br><b>Zigzag Mini.</b> Kliknij link z przytrzymanym Shift, aby go obejrzeć, nie tracąc miejsca, w którym jesteś.</td>
    <td width="50%"><img src="../../site/assets/clips/reader.jpg" alt="Esej z The Public Domain Review w Czytniku"><br><b>Czytnik.</b> Długie teksty bez zbędnych elementów.</td>
  </tr>
</table>

<p align="center"><sub>Więcej, w ruchu, na <a href="https://zigzagbrowser.com">zigzagbrowser.com</a>.</sub></p>

## Co potrafi

| | |
|---|---|
| **Przestrzenie** | Każda ma własny kolor, ikonę, przypięte karty i foldery. Aby przełączać, przesuń dwoma palcami po pasku bocznym albo szturchnij kółko myszy w bok. |
| **Ulubione** | Najczęściej używane witryny jako kafelki nad każdą przestrzenią. Każda karta, przypięta karta lub ulubiona może mieć własne emoji albo symbol. |
| **Profile** | Oddziel pracę od spraw prywatnych. Każdy profil ma własne rozszerzenia, logowania, historię i ulubione, a każda przestrzeń należy do jednego z nich. |
| **Witryny w przestrzeniach** | Wybierz przestrzeń dla witryny w panelu „Ustawienia witryny” lub w „Ustawienia” › „Przestrzenie”, a jej linki będą się tam otwierać, skądkolwiek pochodzą: z innej aplikacji, z ⌘T albo z innej przestrzeni, jak w Air Traffic Control w Arc. Ścieżki też mogą trafiać do własnych przestrzeni, na przykład `github.com/org1` do jednej, a `github.com/org2` do drugiej. Przestrzeń z własnym profilem działa jak kontener Firefoksa. |
| **Pasek poleceń** | ⌘T lub ⌘L. Znajduje otwarte karty, historię i witryny. Wpisz `you`, naciśnij Tab i już szukasz w YouTube. Przeciągnij pasek w dowolne miejsce okna, a od tej pory będzie się tam otwierał. |
| **Grupy kart** | Zaznacz kilka kart i wybierz „Grupuj karty”, a staną się folderem na pasku bocznym, który otwiera się i zamyka, zmienia nazwę i przenosi jako całość. Przeciągnij kartę w prawo, aby zagnieździć ją pod kartą powyżej, a w lewo, aby ją wyjąć. |
| **Foldery na żywo** | Przypięty folder, który wypełnia się sam z kanału lub witryny albo z GitHuba: pull requesty, prośby o recenzję albo otwarte zgłoszenia i pull requesty w twoich repozytoriach. Nowe strony mają kropkę. |
| **Split View** | Do czterech kart: przeciągnij kartę na krawędzie strony, aby zająć połowę, albo na jej rogi, aby zająć ćwiartkę. Przeciągnij stronę za jej pasek, aby ją przenieść, i przypnij widok, aby go zachować. |
| **Okna** | Przeciągnij kartę do innego okna, a przeniesie się w niezmienionym stanie, bez ponownego wczytywania. Włącz „Ustawienia” › „Karty” › „Okna współdzielą karty przestrzeni”, a każde okno z daną przestrzenią pokaże te same karty, jak w Arc. Pasek boczny może być po lewej lub po prawej stronie. |
| **Aplikacje WWW** | „Zainstaluj jako aplikację” zamienia witrynę w osobną aplikację w folderze Aplikacje, w Docku i w ⌘Tab, z paskiem narzędzi w kolorze witryny. |
| **Miniodtwarzacz** | Opuść kartę, gdy odtwarza wideo, a wideo podąży za tobą w małym odtwarzaczu. Zmieniaj jego rozmiar od dowolnej krawędzi i umieść go gdziekolwiek, nawet poza oknem, nad innymi aplikacjami. Wyłącz go w jego menu, jeśli wolisz go nie mieć. Przełącz się do innej aplikacji, a wideo będzie unosić się nad nią w trybie Obraz w obrazie. |
| **Streaming** | Chroniona muzyka i wideo odtwarzają się jak w Safari, przez FairPlay Streaming w WebKit: działa odtwarzacz internetowy Spotify i inne usługi obsługujące Safari. |
| **Teraz odtwarzane** | Każda karta odtwarzająca dźwięk w tle dostaje kartę u dołu paska bocznego, do trzech, aby ją wstrzymać lub wyciszyć. |
| **Wszystkie karty** | ⇧⌘\ pokazuje wszystkie przestrzenie naraz. Wpisz tekst, aby filtrować, przeciągnij kartę do innej przestrzeni. |
| **Wyczyść** | Zamyka karty, od których się oddaliłeś, i zostawia te, nad którymi pracujesz. Wskaż je, aby zobaczyć, które zamknie. Split View zostaje albo znika w całości. „Cofnij” przywraca je. |
| **Zigzag Mini** | ⌃⌘N otwiera małe okno na jedną szybką stronę, a ⌘O przenosi ją do okna przeglądarki. Kliknij link z przytrzymanym Shift albo wybierz „Otwórz link w Zigzag Mini”, a otworzy się w nim nad twoim oknem; ⌘O umieszcza go w karcie obok tej, w której kliknąłeś, a Esc go zamyka. Linki z innych aplikacji otwierają się w nim jak w Little Arc (wyłącz to w „Ustawienia” › „Zigzag Mini”), a „Otwórz w Zigzag Mini” przenosi kartę do jednego z nich. |
| **Hasła** | W Pęku kluczy na Macu, synchronizowane przez Pęk kluczy iCloud. Touch ID, generator i kontrola haseł słabych i używanych wielokrotnie. Klucze dostępu działają. |
| **Ciemne strony** | Jasne witryny rysowane na ciemno silnikiem Dark Reader, z jego poprawkami dla tysięcy witryn, dzięki czemu zdjęcia zachowują wierność. Witryny z własnym ciemnym wyglądem go zachowują. Czysta czerń, jeśli wolisz ciemniej. Włączone wszędzie lub dla wybranej witryny. |
| **Blokowanie reklam** | Wbudowane i włączone: około 130 000 reguł EasyList, EasyPrivacy i EasyList China, skompilowanych do list reguł treści WebKit, a do tego listy filtrów uBlock Origin, które aktualizują się same. |
| **WebRTC** | Włącz „Chroń adres IP przed WebRTC”, a witryny nie dowiedzą się twojego prawdziwego adresu IP przez WebRTC, gdy korzystasz z proxy lub VPN. Połączenia działają w witrynach, na które zezwolisz, a witryna, która próbuje użyć WebRTC, gdy jest zablokowane, informuje o tym, z opcją „Zezwól dla tej witryny”. |
| **Banery cookie** | Odrzucane za ciebie, nigdy nie akceptowane, według reguł Autoconsent od DuckDuckGo. Zostaw je w spokoju wszędzie albo dla jednej witryny, jeśli wolisz odpowiadać samodzielnie. |
| **Ustawienia witryny** | Jeden panel na witrynę: powiększenie, uprawnienia (kamera, mikrofon, lokalizacja, powiadomienia, wyskakujące okna, otwieranie aplikacji, udostępnianie ekranu, WebRTC), każde ustawione na „Pytaj”, „Zezwól” lub „Zablokuj”, JavaScript włączony lub wyłączony, certyfikat, rozszerzenia oraz przełączniki ciemnych stron, blokowania reklam i banerów cookie. Gdy witryna o coś prosi, pyta na jednej karcie nad stroną, na tym razie lub na stałe, a witryna, której odmówisz, przestaje pytać. |
| **Boosts** | „Ukryj element” ukrywa części witryny, których nie chcesz, na przykład baner lub pasek boczny, a „Edytuj styl” dodaje witrynie twój własny CSS. Oba są w menu ⋯ panelu „Ustawienia witryny” i zostają przy witrynie. |
| **Tryb programisty** | Dla witryn, które budujesz, na początek `localhost`: konsola z licznikiem błędów, „Zbadaj element”, rozmiary urządzeń, jasny i ciemny wygląd, style do druku, JavaScript, obrazy lub style wyłączone, inny user agent i kod QR do otwarcia strony na telefonie. |
| **Rozszerzenia** | Z Chrome Web Store, gdzie przycisk sklepu brzmi „Dodaj do Zigzag”. 1Password, Bitwarden, Dark Reader, Tampermonkey i większość popularnych działają; poniżej opisano, co nie działa. |
| **Import** | Zakładki, historia, hasła, logowania i rozszerzenia z Arc, Chrome, Safari, Dia, Edge, Brave, Vivaldi, Opera, Comet, Helium, Yandex, Whale, Chromium, Thorium, Firefox, Zen i Orion. |
| **Pobrane** | Wysyłaj pliki danego typu do osobnego folderu albo otwieraj bezpieczne, takie jak PDF-y, po zachowaniu. Reguły przekazują link lub pobranie do aplikacji, skryptu albo menedżera pobierania, takiego jak aria2, zawsze po zapytaniu. Zobacz [docs/download-rules.md](../../docs/download-rules.md). |
| **Automatyzacja** | AppleScript, Skróty i `osascript` mogą wyświetlać i otwierać karty oraz czytać strony, w sposób przyjęty w Safari i Chrome. Zobacz [docs/automation.md](../../docs/automation.md). |
| **Aplikacje AI** | Wyłączone, dopóki ich nie włączysz: aplikacje AI na twoim Macu mogą używać twoich kart przez MCP, nigdy okien prywatnych ani haseł. Zobacz [docs/automation.md](../../docs/automation.md#ai-apps-mcp). |
| **Twoje dane** | „Plik” › „Eksportuj dane…” zachowuje zakładki jako standardowy plik HTML, który zaimportuje każda przeglądarka, oraz pełną kopię zapasową Zigzag, którą można przywrócić na innym Macu. |
| **Języki** | Angielski, chiński uproszczony, chiński tradycyjny, japoński, koreański, niemiecki, francuski, włoski, hiszpański, portugalski brazylijski, rosyjski, niderlandzki, polski i turecki. |
| **Oraz** | Czytnik, przeglądarka PDF, Handoff na iPhone'a, iPada lub innego Maca, przechwytywanie obszaru, fragmentu strony albo całej strony (⇧⌘2), tłumaczenie na urządzeniu, wyszukiwanie na stronie zaznaczające każde trafienie, menu „Historia” z pozycją „Ostatnio zamknięte” i ostatnimi siedmioma dniami, domyślne powiększenie strony, pasek adresu nad stroną, jeśli wolisz go mieć, Obraz w obrazie, okna prywatne, Inspektor WWW. |

## Czego brakuje

To moja codzienna przeglądarka, ale Zigzag jest młody i znajdziesz w nim błędy. Rzeczy, które zauważą użytkownicy Arc:

- Brak synchronizacji między Macami ani z iPhone'em. Hasła synchronizują się przez Pęk kluczy iCloud; przestrzenie i karty nie.
- Ikony przestrzeni nie przenoszą się z Arc; wybierz je ponownie w Zigzag. Kolory przestrzeni przenoszą się jako najbliższy kolor Zigzag.
- Brak Easeli i Notatek, a Boosts to tylko CSS („Ukryj element” i „Edytuj styl”, bez skryptów dla witryn). Brak AI wbudowanego w przeglądarkę: aplikacje AI mogą używać Zigzag przez MCP tylko wtedy, gdy to włączysz.
- Brakuje kilku API rozszerzeń Chrome: API grup kart, ustawień debuggera, logowania do konta Google w Chrome (`identity.getAuthToken`) oraz starego blokowania żądań webRequest. Rozszerzenia proxy mogą ustawić stały proxy HTTP, HTTPS lub SOCKS5, ale nie skrypt PAC, więc tryb Proxy by Patterns w FoxyProxy nie działa.
- EasyList i pozostałe wbudowane listy blokujące aktualizują się wraz z Zigzag, a nie same; tylko listy uBlock Origin aktualizują się same.
- Tylko macOS 15.4 lub nowszy.

## Jak jest zbudowany

Zigzag to około 120 000 linii Swift 6 i AppKit wokół `WKWebView`. Nie ma w nim Chromium ani Electrona: silnikiem jest WebKit dostarczany z macOS, dlatego aplikacja jest mała, a poprawki bezpieczeństwa silnika przychodzą z aktualizacjami macOS, a nie ode mnie.

| Część | Jak |
|---|---|
| **Strony** | Jeden `WKWebView` na kartę. Karty, których od dawna nie używasz, mogą zostać uśpione: widok internetowy jest zwalniany, a karta zachowuje swój obraz i stan, po czym wczytuje się ponownie, gdy do niej wrócisz. Okna prywatne używają nietrwałego magazynu danych. |
| **Rozszerzenia** | Obsługa rozszerzeń internetowych w WebKit (`WKWebExtensionController`, powód minimum macOS 15.4). Zigzag pobiera pakiet CRX3 z Chrome Web Store, sprawdza jego podpisy i go ładuje. API Chrome, których WebKit nie ma (historia, zakładki, pobieranie, powiadomienia, panele boczne, strony offscreen, logowanie przez internet, dźwięk kart, strony nowej karty, skrypty użytkownika, proxy i inne), obsługuje sam Zigzag przez niewielki most, sprawdzany względem uprawnień każdego rozszerzenia. Wyszukiwarka dodana przez rozszerzenie (`search_provider`) trafia na listę wyborów w ustawieniach i jest używana dopiero po jej wybraniu. Native messaging łączy aplikacje pomocnicze 1Password i innych rozszerzeń. |
| **Piaskownica** | Obrazy i PDF-y z witryn są odczytywane w dwóch izolowanych pomocnikach XPC, `ZigzagImageDecoder` i `ZigzagPDFRenderer`, bez dostępu do sieci i plików, więc uszkodzony obraz lub PDF nie dosięgnie twoich haseł ani profili. Przeglądarka PDF rysuje strony wyrenderowane przez pomocnika; aplikacja nigdy sama nie otwiera PDF-a z witryny. |
| **Bezpieczne połączenia** | Ostrzeżenia o certyfikatach wyjaśniają, co jest nie tak, w sekcji „Szczegóły”. Witryna, która zażądała wyłącznie bezpiecznych połączeń przez nagłówek HSTS lub z listy preload Chromium (dołączonej, około 95 000 nazw, odczytywanej w miejscu tylko wtedy, gdy wymaga tego ostrzeżenie), nie dostaje opcji „Odwiedź tę witrynę mimo to”, jak w Safari i Chrome. Witrynie, która prosi o certyfikat identyfikujący ciebie, są proponowane te z twojego Pęku kluczy, które przyjmie, jak w Safari: dodasz taki, otwierając jego plik .p12 w Dostępie do kluczy. |
| **Blokowanie reklam** | EasyList, EasyPrivacy i EasyList China, wcześniej skonwertowane przez SafariConverterLib do list reguł treści (`WKContentRuleListStore`), kompilowane raz i buforowane. Listy uBlock Origin, pobierane w miarę wygasania, są dopasowywane przez silnik adblockera Ghostery we własnym kontekście JavaScript, a każda strona dostaje skryptlety i reguły ukrywania potrzebne jej witrynie, gdy zaczyna się wczytywać. |
| **Ciemne strony** | Dynamiczny motyw Dark Reader i jego poprawki dla witryn, dołączone, we własnym świecie skryptów. Strony są najpierw informowane, że okno jest ciemne, więc witryna z własnym ciemnym motywem go używa i zostaje nietknięta. |
| **Banery cookie** | Autoconsent od DuckDuckGo i jego reguły, dołączone, we własnym świecie skryptów. |
| **Hasła** | Zachowywane jako elementy Pęku kluczy, więc synchronizuje je Pęk kluczy iCloud, a odblokowuje Touch ID. Klucze dostępu korzystają z uprawnienia Apple dla kluczy dostępu w przeglądarkach. Autouzupełnianie to mały skrypt treści, który wypełnia tylko pola widoczne dla ciebie. |
| **Import** | Odczytuje własne pliki każdej przeglądarki: `StorableSidebar.json` z Arc, zakładki i historię SQLite z Chromium, `Bookmarks.plist` z Safari, `places.sqlite` z Firefoksa, `favourites.plist` i `history` z Oriona. Hasła z Chromium są odszyfrowywane kluczem z elementu Pęku kluczy tej przeglądarki, po zapytaniu macOS o zgodę. |
| **Twoje dane** | Przestrzenie, przypięte karty i ulubione w `Library.json`, profile w `Profiles.json`, otwarte karty w `Session.json`, historia w SQLite (jeden plik na profil), wszystko w `~/Library/Application Support/Zigzag`. Zapisy są opóźniane i atomowe, a plik, którego nie da się odczytać, jest odkładany na bok i nigdy nie nadpisywany. |
| **Czytnik** | Readability od Mozilli, uruchamiane na stronie, wyświetlane własną typografią Zigzag. |
| **Aplikacje WWW** | Witryna zainstalowana jako aplikacja to osobna mała aplikacja w `~/Applications/Zigzag Apps`, która przekazuje każde uruchomienie do Zigzag, więc strona działa w Zigzag z twoimi logowaniami, rozszerzeniami i blokowaniem. |
| **Aktualizacje** | Sparkle 2, z aktualizacjami podpisanymi EdDSA z zigzagbrowser.com, w kanale stabilnym lub beta. Wydania są podpisywane Developer ID i notaryzowane. |

Kod źródłowy jest zorganizowany według funkcji: `Sidebar`, `Tabs`, `Web`, `Extensions`, `Passwords`, `Import`, `Profiles`, `CommandBar`, `Desk` (wszystkie karty naraz), `WebApps`, `Developer`, `MCP` (aplikacje AI), `Settings`, `Window` i `Design` (własne rysowane kontrolki i tokeny projektowe Zigzag). Ponad 2000 testów obejmuje import, hasła, rozszerzenia, obsługę adresów, historię, aplikacje AI i poprawki bezpieczeństwa.

## Prywatność

Bez konta, bez analityki, bez telemetrii. Nic o tym, jak przeglądasz, nie jest do mnie wysyłane. To jedyne połączenia, jakie Zigzag nawiązuje samodzielnie, poza stronami, które otwierasz:

- **Aktualizacje.** Co kilka godzin oraz po wybudzeniu Maca Zigzag odczytuje kanał aktualizacji na zigzagbrowser.com. Żądanie podaje wersję Zigzag i nic więcej; nie jest wysyłany żaden profil systemu. Nowa wersja pobiera się stamtąd.
- **Podpowiedzi wyszukiwania.** Gdy piszesz w pasku adresu, tekst trafia do twojej wyszukiwarki po podpowiedzi, bez plików cookie. Oferują je Google, DuckDuckGo, Brave, Bing, Kagi i Ecosia; w przypadku każdej innej wyszukiwarki nic nie jest wysyłane. Wyłącz je w „Ustawienia” › „Wyszukiwanie”.
- **Ikony witryn.** Ikony pochodzą z samych witryn, także dla przypiętych kart, ulubionych i zaimportowanych zakładek, których jeszcze nie otworzyłeś.
- **Listy filtrów.** Przy uruchomieniu, a potem w miarę wygasania, co kilka godzin do raz na dzień, Zigzag pobiera listy filtrów uBlock Origin z własnych adresów uBlock Origin (GitHub Pages, Cloudflare Pages lub jsDelivr), a jego skryptlety z CDN Ghostery. Pobiera też krótką listę poprawek witryn Zigzag z zigzagbrowser.com. Żądania nie zawierają plików cookie ani niczego o tobie i twoim przeglądaniu.
- **Rozszerzenia.** Instalacja pobiera rozszerzenie z Chrome Web Store. Przy uruchomieniu, najwyżej raz na dzień, Zigzag pyta sklep, czy twoje rozszerzenia mają aktualizacje, co wysyła Google ich identyfikatory i wersje.
- **Konfiguracja.** Ekrany powitalne pokazują kilka ikon witryn z usługi ikon Google i wczytują stronę główną Wikipedii jako podgląd.

Tłumaczenie działa na twoim Macu, z użyciem tłumaczenia na urządzeniu od Apple. Ostrzeżenia o oszukańczych witrynach pochodzą z samego WebKit, tak samo jak w Safari. Hasła pozostają w Pęku kluczy na Macu i synchronizują się wyłącznie przez twój własny Pęk kluczy iCloud. „Pomoc” › „Zgłoś problem…” tworzy raport, który możesz najpierw przeczytać, a nic nie jest wysyłane, dopóki sam tego nie zrobisz. Lista haseł na Macu prowadzi niewielki dziennik swoich kroków w `~/Library/Logs/Zigzag/passwords.log`, nigdy z loginem ani witryną, i zostaje on na twoim Macu. Twoja karta Zigzag jest tworzona na twoim Macu z nazwy twojego konta i dnia pierwszego uruchomienia Zigzag, a jej obraz zawiera tylko to, co pokazuje karta.

## Instalacja

Pobierz DMG z [zigzagbrowser.com](https://zigzagbrowser.com/download), otwórz go i przeciągnij Zigzag do folderu Aplikacje. Albo przez Homebrew:

    brew install --cask zigaowang/tap/zigzag

Aktualizacje instalują się same. Co zmieniło się w każdej wersji, opisują [informacje o wydaniu](https://zigzagbrowser.com/release-notes) i [CHANGELOG.md](../../CHANGELOG.md).

## Opinie

- **Błędy i pomysły:** [zgłoś problem](https://github.com/ZigaoWang/zigzag/issues/new/choose) albo użyj „Pomoc” › „Wyślij opinię…” w aplikacji. W przypadku błędu „Pomoc” › „Zgłoś problem…” tworzy raport, który możesz przeczytać przed wysłaniem.
- **E-mail:** a@zigao.wang
- **Problemy z bezpieczeństwem:** zobacz [SECURITY.md](../../SECURITY.md). Nie publikuj ich w publicznych zgłoszeniach.

## Kompilacja ze źródeł

Wymagania: macOS 15.4 lub nowszy, Xcode 27 lub nowszy i [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
git clone https://github.com/ZigaoWang/zigzag.git
cd zigzag
xcodegen generate
open Zigzag.xcodeproj
```

Uruchom schemat **Zigzag**. Kompilacje Debug działają jako osobna aplikacja, „Zigzag Dev”, z własnymi danymi, więc nigdy nie dotykają twojego codziennego Zigzag.

Podpisywanie jest ustawione dla mojego zespołu. Aby skompilować na swoim Macu, zmień dwie rzeczy w `project.yml` i ponownie uruchom `xcodegen generate`:

- `DEVELOPMENT_TEAM`: identyfikator twojego zespołu (pokazuje go Xcode › Settings › Accounts).
- `PRODUCT_BUNDLE_IDENTIFIER` w Debug: własny, na przykład `com.yourname.zigzag.dev`, ponieważ `wang.zigao.zigzag.dev` jest zarejestrowany na mój zespół.

Uruchom testy:

```sh
xcodebuild test -project Zigzag.xcodeproj -scheme Zigzag
```

## Współtworzenie

Wkład jest mile widziany. Przeczytaj [CONTRIBUTING.md](../../CONTRIBUTING.md), aby dowiedzieć się, jak projekt jest budowany, testowany i stylizowany.

## Licencja

Kod Zigzag jest udostępniany na licencji [Apache License, Version 2.0](../../LICENSE). Używaj go, zmieniaj, forkuj i rozpowszechniaj, komercyjnie lub nie.

Nazwa „Zigzag”, ikona aplikacji i logo nie są objęte licencją: są znakami towarowymi, wszelkie prawa zastrzeżone. Fork potrzebuje własnej nazwy i ikony. Zobacz [TRADEMARKS.md](../../TRADEMARKS.md) i [NOTICE](../../NOTICE). Prace osób trzecich, z których korzysta Zigzag, wymieniono w [THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md).

## Podziękowania

Dziękuję społeczności [LINUX DO](https://linux.do) za wczesne wypróbowanie Zigzag i podzielenie się opiniami.

<p align="center">
  <a href="https://linux.do"><img src="https://shorturl.at/ggSqS" alt="LINUX DO" /></a>
</p>
