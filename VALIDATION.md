# Validation du code source

Le code comprend deux modes, un catalogue hiérarchique, une bibliothèque locale transactionnelle, une file de manifestes et des adaptateurs PC. Cette mise à jour de source ne constitue pas une validation native complète ni une preuve d'installation.

## Recette locale reproductible

`python3 -B Scripts/test-context-library.py` compile le vrai domaine et moteur dans une copie temporaire, puis exécute `Tests/ContextLibraryTests.swift` avec stockage isolé. Les assertions couvrent les contextes et namespaces, l'activation future, les copies/déplacements, collisions, reprise et annulation, les séquences et les limites de cache. Le résultat effectif est imprimé par la commande.

`python3 -B -m unittest discover -s Tests -p 'test_*.py'` exécute les fixtures Python d'observation, relais et transport. Les noms de projets, chemins et connexions y sont synthétiques. Les autres tests Swift présents sont des points d'entrée distincts ; ils ne sont pas tous exécutés par la commande de bibliothèque.

## Preuves distinctes

Les contrôles headless locaux ne prouvent pas les interactions AppKit, le focus, la géométrie réelle des fenêtres, la visibilité près d'une encoche ou l'accord humain. Les interruptions injectées aux checkpoints testent la logique de reprise ; elles ne simulent pas une coupure électrique matérielle.

La recette native Windows PowerShell/C#, les transferts et retours réels, le relais Blender actuel, F12/Ctrl-F12 et l'export opt-in doivent être vérifiés sous les empreintes effectivement déployées. Un ancien relais ou bundle ne valide pas les nouveaux fichiers. Aucun playback ou résultat artistique n'est déduit des tests de code.

Les anciennes configurations, journaux, bases, médias et preuves internes sont exclus du payload public. Les modifications proposées s'appliquent sur l'historique distant existant, sans réécriture de branche.

## Correctifs 0.9.1

Le démarrage `--mac-only` désactive le suivi PC avant la collecte et conserve les autres préférences. Les reçus de production locaux sont liés au manifeste, à la scène, au script et à l’identité du processus. Un compteur déclaré ou un reçu terminé ne prouve pas la présence ni la finalisation physique des sorties. L’analyse AST lit le script sans l’exécuter et refuse les contrats ambigus. Le focus et la réduction de transparence déterminent la politique d’opacité ; les tests de cette politique ne prouvent pas le rendu visuel natif.

`python3 -B Scripts/test-context-library.py --receipt` exécute uniquement les fixtures locales de reçu et d’analyse AST. `python3 -B Tests/test_direct_render_ast.py` vérifie les cas AST adverses sans exécuter le producteur. Ces commandes ne contactent aucun PC et ne lancent aucun rendu.

## Mise à jour 0.9.2

La cadence moyenne utilise seulement les durées valides du reçu lié au job courant ; les durées héritées sont exclues et les absences restent indéterminées. La vignette correspond au dernier PNG terminé, lié au même job et vérifié par empreinte, taille et identité du fichier. Son décodage est limité à 420 pixels ; les demandes du compact masqué sont retirées tout en conservant celles du détail. Le second clic sur la barre masque la fenêtre détachée ; le suivant réutilise cette fenêtre et sa géométrie.

La commande `python3 -B Scripts/test-context-library.py --timing` exécute les fixtures de cadence, de PNG et de visibilité. Les interactions et la géométrie natives doivent être contrôlées séparément.
