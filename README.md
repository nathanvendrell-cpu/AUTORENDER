# AUTORENDER

Application macOS native de suivi des rendus Mac et PC configurés. Les observateurs ne démarrent ni n'arrêtent les moteurs de rendu.

## Deux modes

**Suivi et catalogue** conserve les fichiers à leur emplacement. **Bibliothèque gérée** ajoute le classement physique des sorties finalisées, leur journal et une annulation par opération. L'activation concerne les rendus futurs ; les médias antérieurs demandent un aperçu et l'accord sur le lot exact. Le dossier proposé est `~/Movies/AUTORENDER`.

Une sortie doit être attribuée et finalisée, puis vérifiée avant le retrait de sa source. Une copie avec source conservée reste indiquée comme telle. L'état d'un fichier ne suffit pas à déclarer un rendu entier rangé : son manifeste doit être complet. L'enregistrement d'un futur Render Result Blender est un choix distinct. Les adaptateurs Windows et cet export nécessitent encore leur validation native.

## Catalogue et suivi

La petite fenêtre présente les rendus actifs qualifiés. Les terminés rejoignent l'historique. Le catalogue regroupe projets, sous-projets connus, scènes et versions ; déclinaisons, types et prises conservent leur contexte. Les libellés identiques n'établissent pas une identité client. Des racines et règles explicitement liées par source permettent de réutiliser le classement ; le contexte inconnu reste « À classer » et bloque le déplacement physique.

Un rendu terminé avec preuve conservée peut être retiré de la présentation et restauré, même lorsque sa source est hors ligne. Cette préférence ne supprime ni catalogue ni média. Les actifs et états inconnus restent protégés. Les sorties classées d'un rendu sont accessibles par une requête paginée, séparée du journal récent.

Les compteurs, étapes et versions restent distincts. Pourcentage et estimation exigent un total et des observations compatibles ; les cas incomplets restent indéterminés. Le nombre d'actifs en barre des menus ne constitue pas un pourcentage global de livraison.

## Construire et vérifier

Avec les outils de développement macOS et Python 3 :

```sh
bash Scripts/build.sh
python3 -B Scripts/test-context-library.py
python3 -B -m unittest discover -s Tests -p 'test_*.py'
```

Le build télécharge la dépendance Sparkle épinglée et produit une application sous `Build/Products.noindex`. Il refuse de remplacer une destination existante : choisir un chemin neuf avec `AUTORENDER_BUILD_APP` si nécessaire. La signature locale ad hoc ne constitue pas une distribution signée et notariée.

La commande de test de bibliothèque compile une copie temporaire des sources et utilise seulement des fichiers synthétiques isolés. Elle ne lance aucune application ni UI, ne contacte pas de PC et nettoie ses processus et fichiers temporaires. Les tests Python utilisent des fixtures ; leur succès ne valide pas l'ABI PowerShell/C# ni un rendu Blender réel.

## État de validation

Voir [VALIDATION.md](VALIDATION.md). La QA locale et les typechecks sont distincts du lancement natif, du déploiement PC, du rendu, du playback et de l'acceptation humaine. Aucune donnée de connexion, configuration utilisateur, preuve privée ou média n'est nécessaire à ce dépôt.

## Correctifs 0.9.1

Le démarrage `--mac-only` désactive le suivi PC avant la collecte et conserve les autres préférences. Les reçus de production locaux sont liés au manifeste, à la scène, au script et à l’identité du processus. Un compteur déclaré ou un reçu terminé ne prouve pas la présence ni la finalisation physique des sorties. L’analyse AST lit le script sans l’exécuter et refuse les contrats ambigus. Le focus et la réduction de transparence déterminent la politique d’opacité ; les tests de cette politique ne prouvent pas le rendu visuel natif.

`python3 -B Scripts/test-context-library.py --receipt` exécute uniquement les fixtures locales de reçu et d’analyse AST. `python3 -B Tests/test_direct_render_ast.py` vérifie les cas AST adverses sans exécuter le producteur. Ces commandes ne contactent aucun PC et ne lancent aucun rendu.

## Mise à jour 0.9.2

La cadence moyenne utilise seulement les durées valides du reçu lié au job courant ; les durées héritées sont exclues et les absences restent indéterminées. La vignette correspond au dernier PNG terminé, lié au même job et vérifié par empreinte, taille et identité du fichier. Son décodage est limité à 420 pixels ; les demandes du compact masqué sont retirées tout en conservant celles du détail. Le second clic sur la barre masque la fenêtre détachée ; le suivant réutilise cette fenêtre et sa géométrie.

La commande `python3 -B Scripts/test-context-library.py --timing` exécute les fixtures de cadence, de PNG et de visibilité. Les interactions et la géométrie natives doivent être contrôlées séparément.
