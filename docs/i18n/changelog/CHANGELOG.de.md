# Änderungsprotokoll

Das sind die Versionshinweise von Zigzag auf Deutsch, übersetzt aus CHANGELOG.md. Die App zeigt die Hinweise zu der Version, die du verwendest, und [zigzagbrowser.com/release-notes](https://zigzagbrowser.com/release-notes) zeigt alle Versionen. Versionen vor 0.10.0 findest du auf Englisch in [CHANGELOG.md](../../../CHANGELOG.md).

## [Unreleased]

## [0.10.0] - 2026-11-25

Zigzag in dreizehn weiteren Sprachen, von Japanisch und Koreanisch bis Deutsch, Französisch, Spanisch und Russisch; Downloadregeln, die die gesicherte Datei übergeben; Live-Ordner, die zeigen, wann sie zuletzt aktualisiert wurden; und chinesisches Pinyin tippen und dann zu Englisch wechseln, ohne dass Leerzeichen übrig bleiben.

### Neu
- Zigzag gibt es jetzt auf Japanisch, mit Apples eigenen japanischen Begriffen aus macOS und Safari. Zigzag folgt der Sprache deines Mac, oder du wählst sie in „Einstellungen“ › „Allgemein“ › „Sprache“.
- Zigzag gibt es jetzt auf Koreanisch, Deutsch, Französisch, Italienisch, Spanisch, Portugiesisch (Brasilien), Russisch, Niederländisch, Polnisch und Türkisch, jeweils mit Apples eigenen Begriffen. Zigzag folgt der Sprache deines Mac, oder du wählst eine in „Einstellungen“ › „Allgemein“ › „Sprache“.
- Eine Downloadregel kann statt der Adresse die Datei übergeben: Stell „Übergeben“ auf „Datei“, dann lädt Zigzag sie zuerst mit der Sitzung der Seite herunter und gibt die gesicherte Datei an die App, das Skript oder den Dienst weiter. Links übergeben weiterhin ihre Adresse, und die Vorlagen einer Dateiübergabe können {file} oder {file_url} für die gesicherte Datei verwenden. Danke an [Lakeland97](https://github.com/Lakeland97). ([#529](https://github.com/ZigaoWang/zigzag/issues/529))
- Das Menü eines Live-Ordners beginnt jetzt damit, wann er zuletzt aktualisiert wurde, etwa „Aktualisiert vor 5 Minuten“, oder mit „Wird aktualisiert …“, während er geladen wird.
- Das Fenster „Neuer Live-Ordner“ bzw. „Live-Ordner bearbeiten“ fragt zuerst nach der Quelle, richtet seine Menüs an den Feldern aus und sagt darunter, was der Ordner zeigen wird und dass er alle 30 Minuten prüft (im Stromsparmodus stündlich). Bleibt der Name leer, wird der Name angezeigt, den der Ordner bekommt, und ein Benutzername, den es bei GitHub nicht geben kann, wird markiert.

### Behoben
- Ist Zigzag Mini über einer Seite geöffnet, bewegt Scrollen über der abgedunkelten Seite nicht mehr die Seite dahinter. Danke an [Lakeland97](https://github.com/Lakeland97). ([#531](https://github.com/ZigaoWang/zigzag/pull/531))
- Der Hinweis, bevor Websites auf Apps auf diesem Mac zugreifen dürfen, nennt die Schritte jetzt in der richtigen Reihenfolge: erst die Einstellung einschalten, dann jede Website in ihren „Website-Einstellungen“ einschalten; schaltest du die Einstellung aus, stoppt das alle Websites. Danke an [Lakeland97](https://github.com/Lakeland97). ([#533](https://github.com/ZigaoWang/zigzag/issues/533))
- In den Einstellungen beginnt eine Liste unter einer Überschrift mit Tasten oder einer Suche daneben, etwa „Von Websites gesichert“ oder „Downloads und Links übergeben“, nicht mehr direkt unter diesen Bedienelementen. Sie hat darunter denselben Abstand wie unter jeder anderen Überschrift. Danke an [Lakeland97](https://github.com/Lakeland97). ([#527](https://github.com/ZigaoWang/zigzag/issues/527))
- Wer mitten im Wort von chinesischem Pinyin zu Englisch wechselt, bekommt keine Leerzeichen mehr zwischen den Buchstaben, weder auf einer Seite noch in der Adressleiste, wie in Chrome.
- Ein durchsichtiger Space mit dem Glas „Klar“ hält die Grafik des Mac nicht mehr beschäftigt, während Zigzag nichts tut, auch nicht auf einer leeren Seite oder in den Einstellungen. macOS hat das ganze Fenster samt Schatten in jedem Frame neu gezeichnet; jetzt zeichnet es nur, wenn sich etwas ändert. Auch der Fortschrittsbalken der Update-Karte läuft nicht mehr weiter, während sie ausgeblendet ist.
