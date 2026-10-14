# AUTORENDER

AUTORENDER 0.7.0 est un moniteur macOS natif des rendus Mac et Shadow supportés. Il relève les sources en lecture seule et ne lance ni n’arrête les moteurs de rendu. Le statut du snapshot figure dans [VALIDATION.md](VALIDATION.md).

## En cours et historique

Le dashboard et le suivi compact s’ouvrent sur **En cours** : uniquement les tâches récentes, qualifiées et encore détectées. Un ancien état `.running`, un PID candidat ou un compteur JSON ne suffit pas à y entrer. Les observations non qualifiées ou inactives restent dans Sources.

Une tâche liée à un contrat producteur supporté et à une identité revalidée peut être visible avant son premier PNG ou JSON. Son compteur reste non mesuré, jamais zéro par défaut. Une longue frame ne la fait pas disparaître entre deux sorties. Un périmètre partagé ou incomplet empêche l’attribution du compteur, pas la visibilité de la tâche qualifiée. Cette qualification ne mesure ni GPU ni progression récente.

**Terminés** et **Archives** sont des sections distinctes. La fin technique d’une séquence native exige le plan complet et les sorties stables vérifiées sur deux observations ; un compteur déclaré complet seul ne suffit pas. Après disparition validée du processus, le collecteur existant réconcilie de façon bornée le dernier périmètre qualifié, sans réassocier un PID ni lancer de nouveau poller. L’historique garde les identités et états datés, pas un faux actif actuel.

Un terminal Shadow antérieurement qualifié par un DTO valide et complet reste dans Terminés lorsque sa source devient indisponible : il est historique, non frais et non actif. Un état inconnu, une couverture partielle, des workers attribués ou des sorties manquantes ne sont pas promus depuis les seuls compteurs. Un actif frais qualifié de même identité remplace l’état terminal antérieur. La nouvelle action Archiver reste désactivée sur un terminal historique ; les préférences d’archives existantes restent distinctes.

Une ligne terminée peut être archivée ou masquée de la liste compacte. Un actif qualifié ne peut pas être masqué. **Options → Réafficher les rendus masqués** restaure le masque d’affichage, indépendamment de la restauration des archives. Ces préférences ne suppriment ni rendus ni catalogue.

## Compteurs et fichiers

La progression utilise un numérateur et un dénominateur cohérents de la même version et de la même étape. Brut et post Shadow restent séparés. Sans mesure attribuable, aucune jauge n’invente un pourcentage. Nom et date de la dernière sortie sont distincts du compteur.

Le raccord natif analyse une grammaire Python statique supportée sans exécuter le producteur ni la scène. Il vérifie identité, arguments courants, empreinte du script et plan. L’enveloppe PNG cohérente et les empreintes stables sur deux observations ne certifient ni décodage intégral, provenance historique, export vidéo final ni qualité artistique.

Le catalogue organise Projet → Travail → Version sans fusion par titre ou extension. Les identités source sont prioritaires ; « Organiser » ajoute des métadonnées locales explicites. Type de travail et format de fichier restent distincts : un travail vidéo peut produire des PNG.

Le détail demande au plus deux aperçus avec états En attente, Chargement, Échec et Disponible. Les dossiers/fichiers locaux vérifiés peuvent être ouverts ou révélés ; un chemin Shadow non monté reste distant. Scans et historique paginé sont bornés, et le nombre inventorié n’est pas un total de rendu. Cadences et estimations sont historiques ; GPU, RAM et réglages ne sont pas inventés depuis un processus global.

Dans la recette finale, les deux aperçus historiques restent En attente parce que les entrées sont non stables et la source Shadow indisponible. L’image décodée et la récupération de cache ne sont pas validées sur ce binaire ; aucun état de fichier n’a été forcé pour contourner cette garde.

## Configuration

Sources suivies contient les dossiers locaux et connexions Shadow déjà autorisées. La découverte est bornée aux contrats supportés, sans exploration universelle. Un worker Shadow nécessite une attribution qualifiée ; une couverture partielle ne prouve pas l’absence d’autres workers.

Le support applicatif conserve le nom `RenduBar`. Configuration, préférences, catalogue, caches, registres et clés SSH restent privés. L’API locale compatible est externe et n’est pas démarrée par AUTORENDER. Quitter le moniteur ne ferme pas les moteurs indépendants.

## Construire

Prérequis : macOS 14 ou ultérieur, compilateur Swift, outils Apple et Python 3 pour les helpers. Le packaging utilise `sips` et `iconutil`.

```sh
bash Scripts/build.sh
```

Le build exige une destination neuve ; `AUTORENDER_BUILD_APP` permet de la choisir. Il contrôle ses entrées et embarque leur manifeste. La signature ad-hoc n’est ni Developer ID ni notarisation Apple. Ce dépôt ne contient pas le bundle installé ni les données de recette.

## Tests

Les tests console sont dans `Tests/`. Les fixtures de présentation fournissent explicitement leur qualification simulée, pas une preuve de détection depuis l’API historique. `ActiveOnlyProjectionTests.swift` décrit sections et masquage ; `NativeScriptIntegrationTests.swift` couvre le raccord avec des fixtures neutres.

```sh
python3 Scripts/check-ui-modules.py
```

Cette commande vérifie interfaces et présentation simulée sans lancer l’application.

Les deux runners ciblés de persistance et de terminal historique utilisent des sources copiées et un stockage temporaire neutre :

```sh
python3 -B Tests/check_catalog_persistence.py
python3 -B Tests/check_historical_terminal.py
```

Seul le runner de persistance instrumente une copie temporaire avant l’écriture atomique ; les sources produit ne contiennent pas de hook de test. Ces fixtures ne prouvent pas l’activité d’un renderer réel.

Le harness facultatif se construit séparément :

```sh
bash Scripts/build-ui-harness50.sh
```

Il contient 50 jobs connus **SIMULÉS**, dont un sous-ensemble actif qualifié, avec stockage et préférences de test. Il ne représente pas 50 rendus réels et ne prouve ni FPS ni performance du binaire normal.

Compilation, fixtures, paquet, installation, gestes natifs, persistance et acceptation sont des preuves distinctes. Le statut précis reste dans [VALIDATION.md](VALIDATION.md).
