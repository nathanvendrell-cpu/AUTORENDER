# AUTORENDER

Application macOS native pour retrouver et suivre les rendus des sources Mac et Shadow configurées. AUTORENDER relève leurs données en lecture seule : il ne lance ni n’arrête les moteurs de rendu.

## Suivi compact et dashboard

Le suivi compact affiche automatiquement tous les jobs connus du catalogue, sans choisir un projet au préalable et sans limite cachée sur le nombre de jobs. Ses lignes compactes et scrollables sont groupées par projet et travail. Chaque version garde ses propres compteurs, état daté et temps restant estimé lorsqu’il est calculable. Les filtres Tous, Direct et Historique ainsi que la recherche sont facultatifs. La barre des menus indique le nombre de jobs actifs ; aucun pourcentage global ne mélange plusieurs travaux ou versions.

Le dashboard organise Projet → Travail → Version. Un seul détail est déployé, avec au plus deux derniers aperçus. La sélection de version est mémorisée par travail et partagée avec le suivi compact. Le bouton « Suivi compact » et le menu de l’application donnent accès à la petite fenêtre ; elle peut aussi être détachée du popover. Les fenêtres se déplacent, se redimensionnent, se réduisent et se rouvrent, avec géométrie mémorisée.

« Organiser » permet de rattacher un job à un travail existant ou à un nouveau travail nommé et de donner un libellé à sa version. Ces choix sont des métadonnées locales : les fichiers et les identifiants source restent intacts. Les identités explicitement fournies par la source sont prioritaires. Sans identité de travail fiable, chaque job reste distinct ; noms et extensions ne provoquent aucune fusion automatique. Les filtres de type de travail utilisent une déclaration source ou utilisateur, séparément du format des fichiers : les PNG d’un travail vidéo ne deviennent pas des travaux Images indépendants.

## Compteurs, activité et estimation

Une progression exige un numérateur et un dénominateur valides de la même version et de la même étape. Les restants valent total moins compteur. Sans total, avec un compteur incohérent ou une mesure périmée, l’état est qualifié ou indéterminé. Les images comptées d’une séquence ne sont pas des exports vidéo finaux. Les étapes Shadow brutes et post restent distinctes ; leur total doit être déclaré et relié au même périmètre, jamais déduit de l’un des compteurs ou codé en dur. Le total peut provenir de l’API ou d’une déclaration validée de la page du moniteur, avec provenance et date.

Une source récente ne prouve pas qu’un rendu est actif. Une tâche Ready indique prêt/planifié, pas un processus actif ; un nombre de processus global ne suffit pas à attribuer une activité à chacun des jobs. Une mesure conservée hors ligne reste datée. Les compteurs d’état sont présentés séparément, sans les convertir en pourcentage de livraison.

La cadence et l’intervalle médian entre sorties sont historiques et issus d’un échantillon borné ; ils ne certifient pas la durée de calcul moteur d’une image. Le temps restant et l’ETA courante ne sont estimés que si activité réelle, fraîcheur, total et cadence récente sont disponibles. À l’arrêt, en pause, hors ligne ou sans données suffisantes, ils restent indéterminés. L’animation des jauges est courte, liée uniquement aux changements mesurés de progression, et figée lorsque le job n’est pas actif ou récent.

RAM, GPU, plans et réglages n’apparaissent que lorsqu’ils sont fournis par la source. Un compteur complet, un fichier stable ou un aperçu lisible ne constitue pas une certification d’achèvement ou de livraison.

## Catalogue, aperçu et historique

Le catalogue local conserve les jobs déjà connus. Un job disparu d’un relevé demeure retrouvable avec son dernier état daté ; il ne compte pas comme actif actuel. Cela ne prouve pas un nouveau lancement lorsque son compteur baisse, ni l’existence de tous les fichiers anciens.

Les relevés courants de fichiers sont bornés : jusqu’à 80 exports Mac récents, et sur Shadow jusqu’à 24 par dossier et 80 combinés. Ces limites de fichiers ne limitent pas le nombre de jobs du catalogue et ne sont jamais utilisées comme total de progression.

L’historique s’ouvre explicitement pour la version sélectionnée et se charge par pages de 40 métadonnées. La couverture complète, partielle ou périmée est indiquée. Le nombre inventorié décrit les fichiers connus dans ce périmètre, pas le total du rendu. Un curseur invalidé par un changement de périmètre ou de configuration demande une actualisation. Les fichiers jamais observés puis supprimés ne peuvent pas être reconstruits.

Les lignes du suivi compact ne chargent aucune image. Seul le détail demande ses deux aperçus visibles, via une file annulable et un cache mémoire borné. « À vérifier » indique une première observation ou un fichier changeant ; « Stable » indique taille/date inchangées pendant le contrôle ; « Lisible » indique un aperçu décodé. Une longue interruption d’écriture ou un remplacement conservant taille/date restent des limites de cette détection.

## Retrouver les fichiers

Un nom ou un bouton dossier ouvre directement le dossier local lié lorsqu’une cible unique est vérifiée. Plusieurs versions ou étapes proposent un menu de cibles exactes ; aucun ancêtre commun n’est deviné. L’accès au détail est séparé de l’ouverture du dossier.

Le dernier fichier local connu et stable peut être révélé et sélectionné dans Finder. Il s’agit du fichier réel du périmètre, pas d’un cache de vignette ou d’une URL d’aperçu. Il n’est pas lancé automatiquement, notamment pour l’audio et la vidéo.

Un chemin Shadow non monté est marqué distant et peut être copié. Un miroir local doit être explicitement configuré et vérifié ; AUTORENDER ne monte pas de partage ni ne crée de connexion automatiquement. Une vérification de chemin reste datée et n’empêche pas un fichier d’avoir été déplacé depuis.

## Configuration locale

Ajouter les dossiers Mac et les chemins absolus Shadow dans « Sources suivies ». Le type de travail d’un dossier peut être déclaré ou laissé non défini. L’application suit uniquement ces dossiers et les sources configurées ; elle ne découvre pas tous les rendus de toutes les applications et ne balaie pas tout le Mac ou Shadow.

Pour compatibilité, le support applicatif reste nommé `RenduBar`. Configuration, catalogue privé `Catalog/jobs.json`, derniers relevés et aperçus restent locaux. Les champs optionnels permettent la migration des anciennes configurations. Une sauvegarde ciblée précède la première modification d’organisation ; une erreur d’enregistrement est signalée.

Le fichier optionnel `monitor-jobs.json` décrit une liste de jobs Mac avec `id` et `dossier`. Les dossiers existants sont importés et les dossiers retirés ne sont pas réimportés automatiquement. `connection.json` contient `host`, `user` et `identityFile` pour un accès SSH déjà autorisé ; aucun accès privé n’est fourni par défaut. `jobContexts` porte les attributions locales de travail/version ; `remoteMirrors` peut relier des racines distantes à des dossiers locaux explicitement choisis. Configuration réelle, clés et catalogue sont privés, hors distribution.

Le moniteur compatible peut fournir les routes `/api/status` et `/api/mac` sur la boucle locale, port 4420. Il est externe, non fourni et non démarré par AUTORENDER. Le suivi des dossiers Mac peut fonctionner sans lui. Quitter AUTORENDER ferme ses sondes ; le serveur moniteur et les moteurs de rendu restent indépendants. Aucun démarrage automatique de session n’est ajouté.

## Construire et vérifier

Prérequis : macOS 14 ou ultérieur, compilateur Swift et outils Apple ; Python 3 et accès SSH existant pour les dossiers Shadow. Les outils de packaging utilisent `sips` et `iconutil`.

```sh
bash Scripts/build.sh
open Build/AUTORENDER.app
```

Le script exige une destination neuve afin de préserver les builds précédents ; `AUTORENDER_BUILD_APP` permet d’en choisir une autre. Il compare les hashes des entrées avant/après compilation et embarque un manifeste. La signature ad hoc n’est pas une notarisation Apple.

Les tests de données sont dans `Tests/`. Le harness UI facultatif se construit séparément :

```sh
bash Scripts/build-ui-harness50.sh
```

Ce bundle distinct affiche en permanence **50 JOBS SIMULÉS** et utilise les mêmes vues SCALE avec 50 records neutres, plusieurs travaux/versions, stockage temporaire et suite de préférences isolée. Collecte, réseau et données client sont désactivés ; ses dossiers et fichiers de démonstration sont temporaires et propres au test. Il ne lance aucun rendu réel. Sa fermeture nettoie son stockage et ses préférences propres après export des mesures de projection UI.

Une mesure de projection dans ce harness n’est ni un temps de frame, ni du FPS, ni la performance du binaire normal sur 50 rendus réels. Compilation, tests de données, recette native sur vraies sources, recette 50 jobs simulés et acceptation humaine sont des preuves distinctes. Un build réussi ne prouve pas la fluidité, l’accessibilité ou la maniabilité des fenêtres.
