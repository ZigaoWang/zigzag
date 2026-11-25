# Wijzigingslogboek

Dit zijn de release notes van Zigzag in het Nederlands, vertaald uit CHANGELOG.md. De app toont de notities bij de versie die je gebruikt, en [zigzagbrowser.com/release-notes](https://zigzagbrowser.com/release-notes) toont alle versies. Versies vóór 0.10.0 staan in het Engels in [CHANGELOG.md](../../../CHANGELOG.md).

## [Unreleased]

## [0.10.0] - 2026-11-25

Zigzag in dertien extra talen, van Japans en Koreaans tot Duits, Frans, Spaans en Russisch; downloadregels die het bewaarde bestand doorgeven; livemappen die laten zien wanneer ze voor het laatst zijn bijgewerkt; en na Chinees Pinyin overschakelen naar Engels zonder losse spaties.

### Nieuw
- Zigzag is nu in het Japans, met Apple’s eigen Japanse termen voor macOS en Safari. Zigzag volgt de taal van je Mac, of kies de taal in Instellingen › Algemeen › Taal.
- Zigzag is nu in het Koreaans, Duits, Frans, Italiaans, Spaans, Braziliaans Portugees, Russisch, Nederlands, Pools en Turks, telkens met Apple’s eigen termen. Zigzag volgt de taal van je Mac, of kies een taal in Instellingen › Algemeen › Taal.
- Een downloadregel kan het bestand doorgeven in plaats van het adres: zet Doorgeven op Bestand, dan downloadt Zigzag het eerst met de sessie van de pagina en geeft daarna het bewaarde bestand aan de app, het script of de service. Links geven nog steeds hun adres door, en de sjablonen van een regel die een bestand doorgeeft, kunnen {file} of {file_url} gebruiken voor het bewaarde bestand. Met dank aan [Lakeland97](https://github.com/Lakeland97). ([#529](https://github.com/ZigaoWang/zigzag/issues/529))
- Het menu van een livemap begint nu met wanneer de map voor het laatst is bijgewerkt, zoals Bijgewerkt 5 minuten geleden, of Bezig met bijwerken… terwijl de map wordt opgehaald.
- Het venster Nieuwe livemap en Wijzig livemap vraagt eerst om de bron, lijnt de menu’s uit met de velden en zegt eronder wat de map zal tonen en dat de map elke 30 minuten controleert (elk uur in de energiebesparingsmodus). Een lege naam toont de naam die de map krijgt, en een gebruikersnaam die GitHub niet kan hebben, wordt gemarkeerd.

### Opgelost
- Als Zigzag Mini boven een pagina open is, verschuift scrollen over de gedimde pagina de pagina erachter niet meer. Met dank aan [Lakeland97](https://github.com/Lakeland97). ([#531](https://github.com/ZigaoWang/zigzag/pull/531))
- De uitleg voordat websites apps op deze Mac mogen bereiken, noemt de stappen nu in volgorde: zet de instelling aan, zet daarna elke website aan in de Website-instellingen van die website, en als je de instelling uitzet, stopt dat voor elke website. Met dank aan [Lakeland97](https://github.com/Lakeland97). ([#533](https://github.com/ZigaoWang/zigzag/issues/533))
- In Instellingen begint een lijst onder een kop met knoppen of een zoekveld ernaast, zoals Bewaard door websites of Downloads en links doorgeven, niet meer direct onder die regelaars. Er blijft dezelfde ruimte onder over als bij elke andere kop. Met dank aan [Lakeland97](https://github.com/Lakeland97). ([#527](https://github.com/ZigaoWang/zigzag/issues/527))
- Als je midden in een woord van Chinees Pinyin naar Engels overschakelt, blijven er geen spaties meer tussen de letters staan, op een pagina of in de adresbalk, net als in Chrome.
- Een doorzichtige space met Helder glas houdt de grafische chip van de Mac niet meer bezig terwijl Zigzag niets doet, zelfs op een lege pagina of in Instellingen. macOS tekende elk frame het hele venster en de schaduw ervan opnieuw; nu gebeurt dat alleen als er iets verandert. De voortgangsbalk van de updatekaart stopt ook met schuiven als die verborgen is.
