# Registro delle modifiche

Queste sono le note di rilascio di Zigzag in italiano, tradotte da CHANGELOG.md. L’app mostra le note della versione che stai usando e [zigzagbrowser.com/release-notes](https://zigzagbrowser.com/release-notes) le mostra tutte. Le versioni precedenti alla 0.10.0 sono in inglese in [CHANGELOG.md](../../../CHANGELOG.md).

## [Unreleased]

## [0.10.0] - 2026-11-25

Zigzag in altre tredici lingue, dal giapponese e dal coreano al tedesco, francese, spagnolo e russo; regole di download che trasferiscono il file salvato; cartelle live che dicono quando si sono aggiornate l’ultima volta; e niente più spazi di troppo quando scrivi in pinyin cinese e passi all’inglese.

### Novità
- Zigzag ora è in giapponese, con i termini giapponesi di Apple per macOS e Safari. Segue la lingua del Mac, oppure sceglila in Impostazioni › Generali › Lingua.
- Zigzag ora è in coreano, tedesco, francese, italiano, spagnolo, portoghese brasiliano, russo, olandese, polacco e turco, con i termini di Apple per ciascuna lingua. Segue la lingua del Mac, oppure scegline una in Impostazioni › Generali › Lingua.
- Una regola di download può trasferire il file invece dell’indirizzo: imposta Trasferisci su File e Zigzag prima lo scarica con la sessione della pagina, poi passa il file salvato all’app, allo script o al servizio. I link trasferiscono comunque il proprio indirizzo, e i modelli di un trasferimento del file possono usare {file} o {file_url} per il file salvato. Grazie a [Lakeland97](https://github.com/Lakeland97). ([#529](https://github.com/ZigaoWang/zigzag/issues/529))
- Il menu di una cartella live ora inizia con l’ora dell’ultimo aggiornamento, come Aggiornata 5 minuti fa, oppure Aggiornamento in corso… mentre scarica i contenuti.
- Le finestre Nuova cartella live e Modifica cartella live chiedono prima la fonte, allineano i menu ai campi e spiegano sotto cosa mostrerà la cartella e che controlla ogni 30 minuti (ogni ora in modalità Risparmio energetico). Se lasci vuoto il nome, vedi il nome che riceverà, e un nome utente che GitHub non può avere viene segnalato.

### Correzioni
- Con Zigzag Mini aperto sopra una pagina, scorrere sulla pagina oscurata non muove più la pagina dietro. Grazie a [Lakeland97](https://github.com/Lakeland97). ([#531](https://github.com/ZigaoWang/zigzag/pull/531))
- La spiegazione prima di consentire ai siti web di raggiungere le app su questo Mac ora indica i passaggi in ordine: attiva l’impostazione, poi attiva ogni sito nei suoi Controlli del sito; disattivando l’impostazione si fermano tutti i siti. Grazie a [Lakeland97](https://github.com/Lakeland97). ([#533](https://github.com/ZigaoWang/zigzag/issues/533))
- In Impostazioni, un elenco sotto un’intestazione con accanto dei pulsanti o una ricerca, come Dati memorizzati dai siti web o Trasferisci download e link, non inizia più subito sotto quei controlli. Lascia sotto di essi lo stesso spazio di ogni altra intestazione. Grazie a [Lakeland97](https://github.com/Lakeland97). ([#527](https://github.com/ZigaoWang/zigzag/issues/527))
- Passare dal pinyin cinese all’inglese a metà parola non lascia più spazi tra le lettere, in una pagina o nella barra degli indirizzi, come in Chrome.
- Uno spazio con trasparenza e vetro Trasparente non tiene più occupata la grafica del Mac mentre Zigzag è fermo, anche su una pagina vuota o in Impostazioni. macOS ridisegnava l’intera finestra e la sua ombra a ogni fotogramma; ora la disegna solo quando cambia qualcosa. Anche la barra di avanzamento del riquadro di aggiornamento smette di scorrere quando è nascosto.
