# Historique des versions

Voici les notes de version de Zigzag en français, traduites de CHANGELOG.md. L’app affiche les notes de la version que vous utilisez, et [zigzagbrowser.com/release-notes](https://zigzagbrowser.com/release-notes) présente toutes les versions. Les versions antérieures à 0.10.0 sont en anglais dans [CHANGELOG.md](../../../CHANGELOG.md).

## [Unreleased]

## [0.10.0] - 2026-11-25

Zigzag dans treize langues de plus, du japonais et du coréen à l’allemand, au français, à l’espagnol et au russe ; des règles de téléchargement qui transfèrent le fichier enregistré ; des dossiers dynamiques qui indiquent leur dernière mise à jour ; et la saisie en pinyin chinois suivie d’un passage à l’anglais sans espaces parasites.

### Nouveautés
- Zigzag est désormais disponible en japonais, avec les termes japonais d’Apple pour macOS et Safari. Il suit la langue de votre Mac, ou choisissez-la dans Réglages › Général › Langue.
- Zigzag est désormais disponible en coréen, allemand, français, italien, espagnol, portugais (Brésil), russe, néerlandais, polonais et turc, avec les termes d’Apple pour chacune de ces langues. Il suit la langue de votre Mac, ou choisissez-en une dans Réglages › Général › Langue.
- Une règle de téléchargement peut transférer le fichier au lieu de l’adresse : réglez Transférer sur Fichier, et Zigzag télécharge d’abord le fichier avec la session de la page, puis transmet le fichier enregistré à l’app, au script ou au service. Les liens transfèrent toujours leur adresse, et les modèles d’un transfert de fichier peuvent utiliser {file} ou {file_url} pour le fichier enregistré. Merci à [Lakeland97](https://github.com/Lakeland97). ([#529](https://github.com/ZigaoWang/zigzag/issues/529))
- Le menu d’un dossier dynamique commence désormais par sa dernière mise à jour, comme Mis à jour il y a 5 minutes, ou Mise à jour… pendant la récupération.
- La feuille Nouveau dossier dynamique ou Modifier le dossier dynamique demande d’abord la source, aligne ses menus sur les champs et indique en dessous ce que le dossier affichera et qu’il vérifie toutes les 30 minutes (toutes les heures en mode Économie d’énergie). Un nom laissé vide affiche le nom que le dossier recevra, et un nom d’utilisateur impossible sur GitHub est signalé.

### Corrections
- Quand Zigzag Mini est ouvert au-dessus d’une page, faire défiler la page assombrie ne fait plus bouger la page derrière. Merci à [Lakeland97](https://github.com/Lakeland97). ([#531](https://github.com/ZigaoWang/zigzag/pull/531))
- Les explications affichées avant d’autoriser les sites web à communiquer avec les apps de ce Mac donnent désormais les étapes dans l’ordre : activez le réglage, puis activez chaque site dans ses Réglages du site ; désactiver le réglage arrête tous les sites. Merci à [Lakeland97](https://github.com/Lakeland97). ([#533](https://github.com/ZigaoWang/zigzag/issues/533))
- Dans Réglages, une liste placée sous un titre accompagné de boutons ou d’une recherche, comme Données stockées par les sites web ou Transférer les téléchargements et les liens, ne commence plus juste sous ces commandes. Elle garde en dessous le même espace que sous tous les autres titres. Merci à [Lakeland97](https://github.com/Lakeland97). ([#527](https://github.com/ZigaoWang/zigzag/issues/527))
- Passer du pinyin chinois à l’anglais au milieu d’un mot ne laisse plus d’espaces entre les lettres, sur une page comme dans la barre d’adresse, comme dans Chrome.
- Un espace translucide avec le verre Transparent n’occupe plus le processeur graphique du Mac quand Zigzag est inactif, même sur une page vide ou dans Réglages. macOS redessinait toute la fenêtre et son ombre à chaque image ; il ne la redessine plus que lorsque quelque chose change. La barre de progression de la carte de mise à jour cesse aussi de défiler quand elle est masquée.
