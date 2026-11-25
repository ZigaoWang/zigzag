# Lista zmian

To informacje o wersjach Zigzag po polsku, przetłumaczone z CHANGELOG.md. Aplikacja pokazuje informacje o wersji, której używasz, a [zigzagbrowser.com/release-notes](https://zigzagbrowser.com/release-notes) pokazuje wszystkie wersje. Wersje sprzed 0.10.0 są po angielsku w [CHANGELOG.md](../../../CHANGELOG.md).

## [Unreleased]

## [0.10.0] - 2026-11-25

Zigzag w trzynastu kolejnych językach, od japońskiego i koreańskiego po niemiecki, francuski, hiszpański i rosyjski; reguły pobierania, które przekazują zachowany plik; foldery na żywo, które pokazują, kiedy ostatnio się zaktualizowały; oraz przełączanie z chińskiego pinyin na angielski bez zbędnych spacji.

### Nowe
- Zigzag jest teraz dostępny po japońsku, z japońskim słownictwem Apple dla macOS i Safari. Zigzag używa języka Maca albo możesz go wybrać w „Ustawienia” › „Ogólne” › „Język”.
- Zigzag jest teraz dostępny po koreańsku, niemiecku, francusku, włosku, hiszpańsku, portugalsku (Brazylia), rosyjsku, niderlandzku, polsku i turecku, ze słownictwem Apple dla każdego z tych języków. Zigzag używa języka Maca albo możesz wybrać język w „Ustawienia” › „Ogólne” › „Język”.
- Reguła pobierania może przekazać plik zamiast adresu: ustaw „Przekaż” na „Plik”, a Zigzag najpierw pobierze go w sesji strony, a potem przekaże zachowany plik do aplikacji, skryptu lub usługi. Linki nadal przekazują swój adres, a szablony reguły przekazującej plik mogą używać {file} lub {file_url} dla zachowanego pliku. Podziękowania dla [Lakeland97](https://github.com/Lakeland97). ([#529](https://github.com/ZigaoWang/zigzag/issues/529))
- Menu folderu na żywo zaczyna się teraz od czasu ostatniej aktualizacji, np. „Zaktualizowano: 5 minut temu”, albo „Aktualizowanie…” w trakcie pobierania.
- Arkusz „Nowy folder na żywo” i „Edytuj folder na żywo” najpierw pyta o źródło, wyrównuje menu z polami i pod nimi opisuje, co folder będzie pokazywał oraz że sprawdza co 30 minut (co godzinę w trybie niskiego zużycia energii). Puste pole nazwy pokazuje nazwę, jaką folder otrzyma, a nazwa użytkownika, której GitHub nie dopuszcza, jest oznaczana.

### Naprawiono
- Gdy Zigzag Mini jest otwarty nad stroną, przewijanie nad przyciemnioną stroną nie przesuwa już strony pod spodem. Podziękowania dla [Lakeland97](https://github.com/Lakeland97). ([#531](https://github.com/ZigaoWang/zigzag/pull/531))
- Objaśnienie przed zezwoleniem witrynom na dostęp do aplikacji na tym Macu podaje teraz kroki po kolei: włącz ustawienie, potem włącz każdą witrynę w panelu „Ustawienia witryny”, a wyłączenie ustawienia zatrzymuje wszystkie witryny. Podziękowania dla [Lakeland97](https://github.com/Lakeland97). ([#533](https://github.com/ZigaoWang/zigzag/issues/533))
- W oknie „Ustawienia” lista pod nagłówkiem z przyciskami lub wyszukiwaniem obok, np. „Zachowane przez witryny” lub „Przekazywanie pobranych plików i linków”, nie zaczyna się już tuż pod tymi elementami. Zachowuje pod nimi tyle samo miejsca co każdy inny nagłówek. Podziękowania dla [Lakeland97](https://github.com/Lakeland97). ([#527](https://github.com/ZigaoWang/zigzag/issues/527))
- Przełączenie z chińskiego pinyin na angielski w środku słowa nie zostawia już spacji między literami, na stronie ani na pasku adresu, tak jak w Chrome.
- Prześwitująca przestrzeń ze szkłem „Przezroczyste” nie obciąża już grafiki Maca, gdy Zigzag nic nie robi, nawet na pustej stronie lub w oknie „Ustawienia”. macOS przerysowywał całe okno i jego cień w każdej klatce; teraz rysuje je tylko wtedy, gdy coś się zmienia. Pasek postępu na karcie aktualizacji też przestaje się przesuwać, gdy jest ukryty.
