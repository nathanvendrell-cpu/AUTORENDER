# Mise à jour AUTORENDER — contrat de release

Sparkle 2.10.0 provient de la distribution officielle. `Resources/Sparkle.lock.json` épingle son archive, l’inventaire du framework et les outils. Le cache sous `Build/Dependencies.noindex` est vérifié à chaque utilisation. Les builds n’activent aucun canal sans configuration réelle signée ; les vérifications et installations automatiques restent désactivées.

`prepare-update-release.py` reçoit un artefact de release explicitement signé Developer ID Application et notarisé, jamais l’application installée. Il valide l’identité, la plateforme, les architectures et les minima macOS de tous les Mach-O, ainsi que la concordance entre la clé fournie et la clé publique du bundle. Il produit une archive, des notes et un appcast signés avec les outils officiels, sans upload ni installation. Aucun accès implicite au Keychain, création de clé, compte ou certificat.

Tous les paramètres suivants doivent désigner des valeurs réelles ; aucune URL n’est fournie par défaut :

```sh
python3 -B Scripts/prepare-update-release.py \
  --app "$SIGNED_NOTARIZED_RELEASE_APP" --output "$FRESH_RELEASE_OUTPUT" \
  --notes "$RELEASE_NOTES" --architectures "$RELEASE_ARCHITECTURES" \
  --feed-url "$REAL_FEED_URL" --download-base-url "$REAL_DOWNLOAD_BASE_URL" \
  --notes-base-url "$REAL_NOTES_BASE_URL" --artifact-url "$REAL_ARCHIVE_URL" \
  --allowed-host "$APPROVED_PUBLISHER_HOST" --max-archive-bytes "$ARCHIVE_SIZE_BOUND" \
  --ed-key-file "$EXTERNAL_PRIVATE_SEED_FILE"
```

La clé est un seed Ed25519 Sparkle en base64, conservé hors dépôt et sortie, avec permissions limitées à son propriétaire. Elle n’est copiée ni journalisée. CryptoKit vérifie la correspondance de clé ; les notes, les alias et le contenu du bundle sont contrôlés avant préparation. L’identité Developer ID, la notarisation et le canal de production sont des prérequis non exercés sur ce Mac ; leur absence bloque la préparation.

`test-software-update.py` ne traverse pas l’installateur : signatures/corruption via l’outil officiel, sélection d’appcast via `SPUUpdater`, puis gardes de callbacks simulés. Une annulation après téléchargement, un quit utilisateur suivi d’un retry et une installation réelle exigent encore une recette autorisée avec le helper Sparkle. Aucun résultat de ces simulations ne prouve le remplacement d’un bundle.

La recette native regroupée porte sur le seul candidat 0.8.0, sans lancer de rendu : fonctionnalités héritées, canal non configuré, puis deux fixtures éphémères pour installation et annulation. Estimation 20–30 minutes, sous disponibilité humaine explicite et bail UI frais. Elle n’autorise ni installation utilisateur ni accès Shadow par elle-même.


## Contrat commun et interop

Le préparateur exporte exactement `7agency.app-update.v1` dans `release.json`, puis signe ses octets exacts avec `sign_update -p` dans `release.json.ed25519` (base64 canonique de 64 octets, suivi d’un newline). Cette signature est distincte de celle de l’archive. Produit `fr.robtech.rendubar`, plateforme `macos`, architecture issue des Mach-O validés (`arm64`, `x86_64` ou `universal2`), canal `stable` par défaut ; `--channel prerelease` exige un choix explicite. URL exacte et hôtes approuvés sont fournis explicitement, puis reliés à l’enclosure générée. Taille et SHA256 concernent l’archive finale ; `publicKeyID` est le SHA256 de la clé publique brute de 32 octets. La clé de confiance et les hôtes restent hors de ce JSON.

L’interop de développement utilise le validateur commun reçu de Direction, passé explicitement dans `AUTORENDER_UPDATE_CONTRACT_REFERENCE` lors de `test-software-update.py`. Une copie éphémère identique du validateur est testée avec clés et archives de fixture ; aucune dépendance runtime ne pointe vers ARQMETER. L’URL HTTPS réservée `.invalid` de ce test reste purement hors réseau et n’est jamais installée comme canal.

L’export **live** des états d’opération vers BRAIN n’est pas implémenté. Le tableau suivant documente le mapping à appliquer, sans annoncer un flux existant ni créer un second schéma :

| Signal et preuve nécessaires | État commun |
|---|---|
| Configuration réelle absente, aucun réseau | `unconfigured` |
| Cycle démarré / attente hors cycle | `checking` / `idle` |
| Feed authentifié, aucune version éligible ; incompatibilité distinguée | `upToDate`, ou `blocked` + `incompatible` |
| Version plus récente et compatible proposée, cible authentifiée disponible | `available` |
| Téléchargement effectif, octets exacts seulement si connus | `downloading` |
| Archive et identité validées, confirmation encore requise | `readyToInstall` |
| Installation / relance effectivement engagée | `installing` / `relaunching` |
| Ancienne application et données vérifiées après annulation | `cancelled` |
| Refus de dépendance / erreur locale qualifiée | `blocked` / `failed` |
| Version cible relue après relance ET conservation des données/préférences prouvée | `succeeded` |

Un callback d’installation, `.skip`, une demande de relance ou un build ne produit jamais `succeeded`. Les callbacks actuels ne publient aucun état BRAIN ; la relecture réelle après relance et la conservation des données restent une gate native distincte.
