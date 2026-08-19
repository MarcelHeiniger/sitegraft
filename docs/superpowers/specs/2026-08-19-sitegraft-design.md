# sitegraft — Design doc

**Date :** 2026-08-19 · **Auteur :** Rosalinde · **Statut :** accepté (self-review faite)

> Ce document est la spec complète de sitegraft. Le plan d'implémentation
> (`docs/plans/2026-08-19-sitegraft-implementation.md`) argumente à partir de ce
> document — les deux voyagent ensemble.

---

## 0. Décisions déjà actées (ne pas rouvrir)

Brainstorming complet avec Marcel, 2026-08-19. Résumé pour mémoire (détail dans le
prompt de mission, pas reproduit ici) :

1. Nom **sitegraft**, commande CLI `sitegraft`.
2. CLI bash modulaire à phases — pas de monolithe, pas de Python/Node, pas de plugin
   WP, pas de web-UI, pas de MCP.
3. Base technique WP-CLI + WXR natif pour le contenu ; options copiées individuellement
   (`wp option get/update`) ; tables propres à un plugin via `wp db export --tables=`.
4. Système de modules enfichables (« graft modules ») — le point d'extensibilité.
5. Phases séparées, re-exécutables : `scan → plan → backup → graft → verify → restore`.
6. Sélection interactive granularité post-types + option-keys, via `gum choose`
   (fallback `fzf`), résultat = manifest figé.
7. Backup intégré à l'outil, host-agnostique, avec `restore.sh` généré.
8. ID-mapping alt→neu via mu-plugin temporaire sur B, hooké sur wordpress-importer.
9. Credentials à deux voies (fichier par profil OU saisie interactive) ; profils
   commitables sans secret.
10. Portabilité bash, dépendances minimales, jamais `scp`.
11. Etch : templates en DB uniquement (pas de fallback fichier) ; navigation souvent
    un bloc dynamique `wp:page-list` — à vérifier par site dans `scan`.
12. Étape optionnelle `clean` dans `graft`.
13. Hardening : `set -euo pipefail`, mktemp+trap, integrity-gate WXR, `--dry-run`
    global, `--authors=skip`, logs colorés, jamais `scp`.

**Précision reçue en cours de conception (déjà intégrée dans tout ce document et tout
le repo) :** `repo/` sera publié en repo GitHub **public** sous le compte
MarcelHeiniger. Conséquences : zéro secret/host réel/IP/nom de client nulle part, pas
même en exemple « réaliste » — uniquement des placeholders génériques
(`example.com`, `user@host`, `<profile>`) ; LICENSE MIT ; README racine en anglais.

### 0.1 Décisions prises seule par Rosalinde pendant la conception (à valider)

Le prompt de mission laissait plusieurs points d'implémentation ouverts
(« décide et documente »). Voici les choix faits, avec justification, à valider par
Marcel avant l'étape 1 du plan :

| # | Décision | Justification |
|---|----------|----------------|
| D1 | **`jq`** comme dépendance pour lire/écrire le manifest en **JSON** | Le manifest a une structure imbriquée par module (post_types × option_keys × tables). Un format KEY=VALUE plat ne le représente pas proprement. `jq` est quasi-universel (`brew install jq` / `apt install jq`), léger, et bien plus sûr qu'un parseur JSON maison en bash. |
| D2 | **Portabilité ciblée bash 3.2** (pas d'associative arrays, pas de `mapfile`) plutôt qu'exiger bash ≥ 4 | macOS système reste en bash 3.2 (licence GPLv3 sur bash 4+). Exiger `brew install bash` casserait la promesse « tourne sur n'importe quel Mac sans rien installer de plus que les dépendances listées ». Le registre de modules est donc une liste de noms (string), pas un tableau associatif — voir §3.4. |
| D3 | **State-dir** : `~/.sitegraft/runs/<profile>-<timestamp>/` sur l'orchestrateur, **jamais nettoyé automatiquement** | Ce dossier contient les seules copies de sécurité inspectables d'un run (manifest, id-map, logs, backup). Une purge automatique serait dangereuse — la rétention/purge reste un geste manuel de l'opérateur (`sitegraft prune` pourrait être ajouté plus tard, YAGNI pour v1). |
| D4 | **Mu-plugin de mapping livré par dépôt de fichier `rsync`** dans `wp-content/mu-plugins/`, pas par `wp plugin install` | Les mu-plugins WordPress se chargent automatiquement dès qu'ils sont présents dans `mu-plugins/` — aucune activation nécessaire, donc aucun état à gérer côté `wp plugin activate/deactivate`. Un simple dépôt + suppression de fichier est plus simple et plus sûr (rien à désactiver si le run crash). |
| D5 | **`bats-core`** comme framework de test unitaire pour les fonctions pures de `lib/` | Standard de facto pour tester du bash, syntaxe proche de test unitaire classique, s'intègre nativement avec `set -euo pipefail`, largement documenté. |

### 0.2 Points à challenger (risques identifiés par Rosalinde)

Signalés explicitement pour que Nat les fasse trancher par Marcel plutôt que de les
enterrer dans le détail technique :

- **R1 — Réimport idempotent (§9.6) repose sur une convention de metadata
  (`_sitegraft_source_id`) que sitegraft doit poser lui-même via le mu-plugin.**
  Si un opérateur importe un jour du contenu sur B par un autre moyen que
  sitegraft, ce garde-fou ne le verra pas. Acceptable pour v1 (outil personnel,
  usage contrôlé) mais à garder en tête si l'outil est un jour utilisé par un tiers.
- **R2 — Le remapping d'ID dans le contenu Etch (§9.1) utilise une technique de
  sentinelles à deux passes sur `wp search-replace --regex`.** C'est robuste sur le
  papier mais n'a encore été validé que par le raisonnement, pas par un run réel
  contre du vrai contenu Etch exporté par une vraie licence. Le harnais DDEV (§10)
  simule ce format sans licence Etch réelle — un écart de format réel vs simulé est
  possible et ne serait détecté qu'au premier vrai run.
- **R3 — Défaut-deny sur les tables/options non réclamées par un module (§3.5) protège
  bien, mais si le scan ne détecte PAS une table (ex. table sans préfixe `$table_prefix`
  standard, ou plugin qui stocke ses données ailleurs qu'en DB), elle n'apparaît jamais
  dans le manifest — ni côté protégé ni côté ignoré. Le risque n'est pas une
  contamination (rien n'est touché si rien n'est sélectionné) mais un faux sentiment
  de complétude du scan.** À documenter clairement dans la sortie de `scan` (« ce scan
  couvre X tables sur Y trouvées en base, vérifiez manuellement si le plugin protégé
  stocke des données hors de ces tables »).
- **R4 — Pas de run pilote prévu avant la fin de la construction complète de l'outil.**
  Le harnais DDEV teste la mécanique, pas la variété réelle du contenu Etch/plugins
  tiers rencontrés en usage réel. Le premier vrai run restera un moment de vérité,
  même avec 100% de tests verts en DDEV.

---

## 1. Vue d'ensemble

```
site A (Etch/ACSS, source)  ──┐
                               ├──►  sitegraft (orchestrateur)  ──►  site B (cible, vivant)
site B (cible, vivant, read)  ─┘
```

sitegraft tourne sur une machine tierce (« l'orchestrateur » — le Mac de Marcel, ou
tout poste avec les dépendances). Il pilote A et B via SSH+wp-cli (ou `ddev wp` en
local). Rien n'est installé de façon permanente sur A ou B — seul un mu-plugin
temporaire touche B, le temps d'un import, puis est retiré.

## 2. Arborescence de l'outil

```
sitegraft/
├── bin/
│   └── sitegraft                       # entrypoint : parse phase + --profile + flags, dispatch vers lib/
├── lib/
│   ├── core.sh                         # logging, couleurs, require_cmd, mktemp+trap, dry-run helper, wrappers ssh/rsync/wp
│   ├── profile.sh                      # chargement profil (profiles/*.conf) + credentials
│   ├── modules.sh                      # découverte/registre/dispatch des modules (convention-based, bash 3.2)
│   ├── inventory.sh                    # phase scan : introspection d'un site (post_types, options, tables, plugins)
│   ├── manifest.sh                     # phase plan : construction, validation, lecture/écriture JSON (jq) du manifest
│   ├── backup.sh                       # phase backup + génération restore.sh
│   ├── graft.sh                        # phase graft : médias, WXR, mu-plugin, remaps, clean optionnel
│   └── verify.sh                       # phase verify : smoke checks + comparaison checksums protégés
├── modules/
│   ├── _template.sh                    # squelette documenté pour écrire un nouveau module
│   ├── core-wp.sh                      # pages, posts, blocks, navigation, templates, styles globaux, médias
│   ├── etch.sh                         # CPTs/options Etch
│   ├── acss.sh                         # options ACSS
│   └── motopress.sh.example            # exemple pédagogique complet — PAS auto-chargé (suffixe .example)
├── mu-plugins/
│   └── sitegraft-id-mapper.php         # template rsyncé sur B pendant graft, retiré après (voir §8)
├── profiles/
│   └── example.conf                    # profil d'exemple, aucun secret
├── tests/
│   ├── unit/
│   │   ├── test_core.bats
│   │   ├── test_manifest.bats
│   │   ├── test_modules.bats
│   │   └── test_graft_remap.bats
│   └── integration/
│       ├── ddev-harness.sh             # orchestration complète du harnais (voir §10)
│       └── fixtures/
│           ├── site-a-seed.sh          # seed contenu Etch simulé sur A
│           └── site-b-fake-plugin/
│               └── fake-plugin.php     # faux plugin protégé, son CPT, sa table, ses options
├── docs/                               # ce dossier
├── LICENSE
├── README.md
└── .gitignore
```

Convention de nommage : le préfixe des fonctions d'un module est le nom de fichier
sans extension, tirets remplacés par underscores. `modules/core-wp.sh` → préfixe
`core_wp_`. `modules/motopress.sh.example` → préfixe `motopress_` (voir §3).

## 3. Le contrat des modules

### 3.1 Principe

Le cœur de l'outil ne connaît **aucun** plugin par son nom. Il connaît uniquement des
« modules » — des fichiers `modules/<nom>.sh` qui déclarent, via des fonctions à
préfixe conventionné, ce qu'ils possèdent. Ajouter un plugin demain = un fichier,
zéro modification de `lib/` ou `bin/`.

Chaque module sert **dans les deux sens** :
- Côté A (source) : ce module dit quoi migrer.
- Côté B (cible) : ce même module dit quoi protéger — si détecté sur B et non
  sélectionné pour migration, tout ce qu'il déclare passe automatiquement en liste
  « ne pas toucher ».

### 3.2 Fonctions conventionnées

Pour un module de préfixe `<mod>` (ex. `core_wp`, `etch`, `acss`, `motopress`) :

| Fonction | Obligatoire | Signature | Rôle |
|----------|:-----------:|-----------|------|
| `<mod>_name` | oui | `<mod>_name` → stdout: nom lisible | Nom affiché dans les prompts `gum choose` |
| `<mod>_detect` | oui | `<mod>_detect <scan_json_path>` → exit 0/1 | Le plugin/domaine est-il présent sur le site scanné ? |
| `<mod>_post_types` | non* | `<mod>_post_types` → stdout: un post_type par ligne | Post types possédés par ce module |
| `<mod>_option_keys` | non* | `<mod>_option_keys` → stdout: une clé `wp_options` par ligne | Options possédées par ce module |
| `<mod>_option_keys_exclude` | non | `<mod>_option_keys_exclude` → stdout: un pattern glob par ligne | Exclusions à l'intérieur d'un préfixe large (ex. licences, versions de DB) |
| `<mod>_tables` | non* | `<mod>_tables` → stdout: un suffixe de table par ligne (sans `$table_prefix`) | Tables SQL propres, hors contenu WXR |
| `<mod>_post_import` | non | `<mod>_post_import <state_dir> <id_map_tsv> <wp_cmd_b>` | Hook exécuté après import WXR + remaps génériques, pour des remaps spécifiques au module |

\* Au moins UNE des trois fonctions `_post_types` / `_option_keys` / `_tables` doit
exister — un module qui ne déclare rien n'a pas de raison d'exister.

`lib/modules.sh` découvre les modules par glob `modules/*.sh` (le suffixe `.example`
est explicitement exclu, tout comme `_template.sh`), source chaque fichier, et
construit `SITEGRAFT_MODULES` — une chaîne de noms séparés par espace (pas de tableau
associatif, contrainte bash 3.2 — voir D2). La présence de chaque fonction optionnelle
est testée avec `type -t <mod>_xxx >/dev/null 2>&1` avant appel.

### 3.3 Exemple concret — `modules/etch.sh`

```bash
#!/usr/bin/env bash
# modules/etch.sh — graft module for Etch (page builder)

etch_name() { echo "Etch"; }

etch_detect() {
  # $1 = path to a scan-*.json produced by `sitegraft scan`
  jq -e '.plugins[] | select(.name == "etch")' "$1" >/dev/null 2>&1
}

etch_post_types() {
  cat <<'EOF'
etch_cfs
etch_cpts
etch_loops
EOF
}

etch_option_keys() {
  cat <<'EOF'
etch_css_toolbar_values
etch_global_stylesheets
etch_settings
etch_styles
EOF
}

etch_option_keys_exclude() {
  cat <<'EOF'
etch_license_*
etch_db_version
EOF
}
```

### 3.4 Exemple de futur module — `modules/motopress.sh.example`

Fourni comme exemple pédagogique complet (pas un vrai module v1 — MotoPress n'est pas
implémenté). Copier ce fichier en `modules/motopress.sh` (sans `.example`) et
l'adapter est le geste attendu pour ajouter un vrai support MotoPress plus tard.

```bash
#!/usr/bin/env bash
# modules/motopress.sh.example — worked example: a hypothetical future module.
# Copy to modules/motopress.sh (drop the .example suffix) to activate it for real.
# MotoPress Hotel Booking is NOT implemented in v1 — this file exists purely to show
# the contract end-to-end, including a table and a post_import remap hook.

motopress_name() { echo "MotoPress Hotel Booking"; }

motopress_detect() {
  jq -e '.plugins[] | select(.slug == "motopress-hotel-booking")' "$1" >/dev/null 2>&1
}

motopress_post_types() {
  cat <<'EOF'
mphb_booking
mphb_room_type
mphb_rate
mphb_room
EOF
}

motopress_option_keys() {
  cat <<'EOF'
mphb_settings
EOF
}

motopress_tables() {
  # Suffixes only — sitegraft prefixes with the live $table_prefix of the site.
  cat <<'EOF'
mphb_room_type_meta
EOF
}

# Example post-import hook: not used for migration in v1 (MotoPress data is always
# in the "protect" bucket, never in "migrate", for the case Marcel described — a live
# B with real bookings). Shown here purely to document the hook signature for a
# future module that DOES migrate a plugin's content.
motopress_post_import() {
  state_dir="$1"
  id_map_tsv="$2"
  wp_cmd_b="$3"
  # Example: if mphb_room_type posts had been migrated, remap a hypothetical
  # "related_room_id" postmeta pointing at another migrated post.
  while IFS=$'\t' read -r old_id new_id post_type; do
    [ "$post_type" = "mphb_room_type" ] || continue
    $wp_cmd_b post list --post_type=mphb_booking --meta_key=related_room_id \
      --meta_value="$old_id" --field=ID | while read -r booking_id; do
        $wp_cmd_b post meta update "$booking_id" related_room_id "$new_id"
    done
  done < "$id_map_tsv"
}
```

### 3.5 Défaut sûr (default-deny)

Pendant `plan`, après avoir fait dialoguer chaque module connu avec les scans de A et
B, tout ce qui reste sur B — post_type, table, ou clé d'option — non réclamé par
aucun module (migré ou protégé) tombe dans un bucket automatique `_unclaimed` du
manifest, marqué protégé. **Rien n'est jamais migré ou effacé par défaut.** Un
opérateur qui veut migrer un élément non couvert doit écrire un module pour lui
(même minimal) — c'est une friction voulue, pas un oubli.

## 4. Format du manifest

Produit par `plan`, figé, consommé tel quel par `graft`. JSON, parsé via `jq`.

```jsonc
{
  "sitegraft_manifest_version": 1,
  "profile": "example",
  "created_at": "2026-08-19T10:00:00Z",
  "frozen": true,
  "site_a": { "url": "https://a.example.com", "alias": "a" },
  "site_b": { "url": "https://b.example.com", "alias": "b" },
  "migrate": {
    "core-wp": {
      "post_types": ["page", "post", "wp_block", "wp_navigation", "wp_template", "wp_template_part", "wp_global_styles"],
      "option_keys": ["show_on_front", "page_on_front", "page_for_posts"],
      "media": true
    },
    "etch": {
      "post_types": ["etch_cfs", "etch_cpts", "etch_loops"],
      "option_keys": ["etch_css_toolbar_values", "etch_global_stylesheets", "etch_settings", "etch_styles"]
    },
    "acss": {
      "option_keys": ["automatic_css_settings", "automatic_css_generated_inventory"]
    }
  },
  "protect": {
    "example-plugin": {
      "post_types": ["example_booking", "example_room_type"],
      "tables": ["example_room_type_meta"],
      "option_keys": ["example_plugin_settings"]
    },
    "_unclaimed": {
      "post_types": ["unknown_cpt_found_on_b"],
      "tables": [],
      "option_keys": [],
      "note": "détecté sur B, aucun module ne le réclame — protégé par défaut-deny"
    }
  },
  "clean": {
    "enabled": false,
    "post_types": []
  },
  "options": {
    "search_replace": { "from": "https://a.example.com", "to": "https://b.example.com" }
  },
  "checksums_protected_pre_graft": {
    "example-plugin": "sha256:…"
  }
}
```

Règles de validation (`lib/manifest.sh :: manifest_validate`) :
- `frozen` doit être `true` pour que `graft` accepte le manifest.
- Aucun post_type/table/option-key ne doit apparaître à la fois dans `migrate` et
  `protect` (conflit → `plan` refuse de figer).
- `checksums_protected_pre_graft` est calculé et écrit par la phase `backup` (pas par
  `plan`), consommé par `verify`.

## 5. Format du profil + credentials

### 5.1 Profil — `profiles/<nom>.conf` (commitable, zéro secret)

```sh
# profiles/example.conf — sitegraft profile. No secrets here — safe to commit.

SITE_A_ALIAS="a"
SITE_A_SSH_HOST="user@host-a.example.com"
SITE_A_WP_PATH="/var/www/site-a/htdocs"
SITE_A_WP_CMD="wp"                      # or "ddev wp" for a local DDEV site
SITE_A_URL="https://a.example.com"

SITE_B_ALIAS="b"
SITE_B_SSH_HOST="user@host-b.example.com"
SITE_B_WP_PATH="/var/www/site-b/htdocs"
SITE_B_WP_CMD="wp"
SITE_B_URL="https://b.example.com"

SITEGRAFT_STATE_DIR="${HOME}/.sitegraft/runs"
SITEGRAFT_CREDS_FILE="${HOME}/.config/sitegraft/example.creds"
```

`SITE_*_SSH_HOST` étant vide signifie « site local, piloté via `SITE_*_WP_CMD`
directement sans SSH » (cas d'un site DDEV local sur l'orchestrateur lui-même).

### 5.2 Credentials — deux voies

**(a) Fichier** `~/.config/sitegraft/<profile>.creds` (chmod 600, gitignored, jamais
commité) :

```sh
SITE_A_SSH_KEY="/absolute/path/to/private_key_a"
SITE_B_SSH_KEY="/absolute/path/to/private_key_b"
```

**(b) Saisie interactive** au lancement (`gum input --password` pour les valeurs
sensibles) si le fichier de credentials référencé par le profil n'existe pas — avec
proposition explicite d'enregistrement (« sauvegarder dans `~/.config/sitegraft/
example.creds` pour ne plus resaisir ? [y/N] »), jamais automatique.

`lib/profile.sh :: profile_load` lit le `.conf` (source shell, donc uniquement des
assignations `KEY="value"` — pas de code arbitraire), puis charge le `.creds`
correspondant s'il existe, sinon déclenche (b).

## 6. Déroulé exact des phases

### 6.1 `scan` (read-only, A et B)

```sh
wp --path="$WP_PATH" post-type list --format=json
wp --path="$WP_PATH" option list --format=json          # dump complet — filtré ensuite par module
wp --path="$WP_PATH" db tables --format=json --all-tables-with-prefix
wp --path="$WP_PATH" plugin list --format=json           # aide à la détection des modules
```
Écrit `scan-a.json` et `scan-b.json` dans le state-dir. Read-only strict — aucune
écriture sur A ou B. Rejouable à volonté.

Vérification spécifique Etch demandée par Marcel (§0 point 11) : le scan interroge
aussi si la navigation de chaque site est un bloc dynamique `wp:page-list` (pas d'IDs
en dur) en inspectant le contenu des `wp_navigation` trouvés — jamais supposé, toujours
vérifié par site, résultat consigné dans `scan-*.json` (`"nav_uses_dynamic_page_list":
true/false`).

### 6.2 `plan` (interactif, écrit seulement en local)

1. Charge `scan-a.json` / `scan-b.json`.
2. Pour chaque module découvert, appelle `<mod>_detect` sur les deux scans.
3. Construit les défauts : modules détectés sur A avec du contenu Etch/ACSS →
   pré-cochés côté migration ; modules détectés sur B et absents de la sélection de
   migration → pré-cochés côté protection.
4. `gum choose --no-limit` (fallback `fzf`, fallback liste numérotée + prompt texte)
   pour ajuster la sélection granulaire (post_types et option_keys individuels).
5. Valide (aucun conflit migrate/protect, voir §4), calcule le bucket `_unclaimed`
   automatiquement, écrit `manifest.json` avec `"frozen": false`.
6. Confirmation explicite (`gum confirm "Figer ce manifest ?"`) → `"frozen": true`.

### 6.3 `backup` (écrit uniquement dans le state-dir orchestrateur — B pas encore touché en profondeur)

```sh
# sur B :
ssh "$SITE_B_SSH_HOST" "wp --path=$SITE_B_WP_PATH db export - --add-drop-table | gzip" \
  > "$STATE_DIR/backup/b-db.sql.gz"
ssh "$SITE_B_SSH_HOST" "tar czf - -C $(dirname "$SITE_B_WP_PATH") wp-content" \
  > "$STATE_DIR/backup/b-wp-content.tar.gz"
```
Puis génère `$STATE_DIR/restore.sh` — un script autonome, portant en dur (dans le
run, pas dans le repo) le chemin du backup et les mêmes commandes wp-cli/rsync
inversées, prêt à relancer sans autre contexte. Calcule aussi
`checksums_protected_pre_graft` (sha256 des exports de tables/options protégées) et
les écrit dans `manifest.json`. Marque `$STATE_DIR/backup.complete` — `graft` refuse
de démarrer sans ce marqueur.

### 6.4 `graft`

1. **Médias** : `rsync -avz --ignore-existing` de `wp-content/uploads/` A → B (jamais
   d'écrasement d'un fichier déjà présent sur B — protège les médias déjà utilisés
   par le plugin protégé en cas de collision de nom).
2. **Mu-plugin** : dépôt de `mu-plugins/sitegraft-id-mapper.php` sur B via `rsync`.
3. **Export WXR sur A**, filtré aux post_types du manifest :
   ```sh
   wp --path="$SITE_A_WP_PATH" export --post_type=page,post,etch_cfs,... --dir=/tmp/sitegraft-export/
   ```
4. **Integrity-gate** (avant tout transfert) sur chaque fichier `.xml` produit :
   taille > 0, présence de `<wp:wxr_version>`, ≥ 1 `<item>`, et **tout**
   `<wp:post_type>` trouvé dans le fichier ∈ la liste `post_types` du manifest —
   abort sinon (protège contre un export wp-cli qui inclurait plus que demandé).
5. **Transfert** WXR A → orchestrateur → B via `rsync` (deux sauts, jamais de
   connexion directe A↔B supposée).
6. **`wordpress-importer`** installé + activé sur B si absent (état pré-existant noté
   pour restauration exacte après import).
7. **Import** :
   ```sh
   wp --path="$SITE_B_WP_PATH" import /tmp/sitegraft-import/*.xml --authors=skip
   ```
   Jamais `--fetch_attachments` — les médias sont déjà en place (étape 1), et le
   comportement par défaut de `wordpress-importer` sans ce flag ne retélécharge rien,
   il attend que le fichier existe déjà au bon chemin (voir §9 pour le détail de ce
   comportement, important à comprendre).
8. **Options** : `wp option get --format=json` sur A pour chaque `option_keys` du
   manifest, `wp option update --format=json` sur B (moins `page_on_front` — voir §9.3).
9. **Rapatriement du log de mapping** (`wp-content/sitegraft-id-map.log` sur B) →
   `$STATE_DIR/id-map.tsv` via `rsync`.
10. **Retrait du mu-plugin** de B, désactivation/désinstallation de
    `wordpress-importer` si sitegraft l'avait installé lui-même.
11. **Remaps** — voir §9 en détail.
12. **`clean` optionnel** (§6.6) si `manifest.clean.enabled = true`.

Chaque sous-étape pose un marqueur `$STATE_DIR/graft.step<N>.done` — un `graft`
interrompu reprend à la sous-étape suivant le dernier marqueur, jamais depuis zéro.

### 6.5 `verify` (read-only sur B)

- Recompte les post_types migrés (A avant vs B après, cohérence attendue).
- Recalcule les checksums des données protégées, compare à
  `manifest.checksums_protected_pre_graft` — **toute divergence = échec dur**.
- Vérifie que `show_on_front`/`page_on_front` de B résout vers une page existante.
- Vérifie la présence de la navigation attendue.
- Vérifie (best-effort, `curl -sS -o /dev/null -w '%{http_code}'`) que l'URL racine de
  B répond 200.
- Écrit `$STATE_DIR/verify-report.md`, exit non-zéro sur échec dur.

### 6.6 `clean` (sous-étape optionnelle de `graft`, jamais seule)

Supprime sur B les types de contenu **sélectionnés pour migration** qui existaient
déjà côté « ancienne couche design » de B avant le graft (jamais les types protégés).
Requiert `backup.complete`. N'agit que sur les post_types listés dans
`manifest.clean.post_types` (sous-ensemble explicite de `migrate`, jamais déduit
automatiquement).

### 6.7 `restore`

```sh
sitegraft restore --profile <profile> --run <run-id> [--yes]
```
Exécute `$STATE_DIR/restore.sh` du run désigné. Avant toute restauration, prend un
mini-backup de l'état courant de B (« backup du backup ») dans un sous-dossier
`pre-restore/` du même run — même une restauration doit rester réversible. Demande
confirmation (`gum confirm`) sauf `--yes`.

## 7. Le mu-plugin de mapping — `mu-plugins/sitegraft-id-mapper.php`

```php
<?php
/**
 * Plugin Name: sitegraft ID Mapper (temporary)
 * Description: Logs old->new post/term ID pairs during a sitegraft WXR import.
 * Installed and removed automatically by `sitegraft graft` — do not install by hand.
 */

add_action( 'wp_import_insert_post', function ( $post_id, $original_post_id, $postdata, $post ) {
    $log = WP_CONTENT_DIR . '/sitegraft-id-map.log';
    $post_type = isset( $postdata['post_type'] ) ? $postdata['post_type'] : 'unknown';
    file_put_contents( $log, "{$original_post_id}\t{$post_id}\t{$post_type}\n", FILE_APPEND | LOCK_EX );
    update_post_meta( $post_id, '_sitegraft_source_id', $original_post_id ); // pour l'idempotence, voir §9.6
}, 10, 4 );

add_action( 'wp_import_insert_term', function ( $term_id, $term, $original_id ) {
    $log = WP_CONTENT_DIR . '/sitegraft-id-map.log';
    file_put_contents( $log, "{$original_id}\t{$term_id}\tterm:{$term}\n", FILE_APPEND | LOCK_EX );
}, 10, 3 );
```

Format du log (`id-map.tsv` après rapatriement) : `old_id<TAB>new_id<TAB>post_type`,
une ligne par post/terme importé. C'est la seule source de vérité pour tout remap
d'ID post-import.

## 8. Comportement par défaut de `wp import` vis-à-vis des médias (important)

`wordpress-importer` **ne retélécharge pas** les fichiers joints par défaut — le flag
`--fetch_attachments` est nécessaire pour ça, et sitegraft ne le passe jamais. Sans
ce flag, l'import crée les posts `attachment` et leur metadata en supposant que le
fichier existe déjà au chemin calculé (`wp-content/uploads/YYYY/MM/fichier.ext`).
C'est exactement pourquoi l'ordre est : **médias en premier** (rsync, étape 1 de
`graft`), **import WXR ensuite** (étape 7). Si l'ordre était inversé, l'import
laisserait des attachments avec fichier manquant.

## 9. Stratégie de remapping post-import

### 9.1 Références d'ID d'image doublement embarquées (contenu Etch)

Etch embarque une référence image de deux façons dans un même bloc : l'attribut
`"id":X` (JSON dans `post_content`) ET une URL absolue `<img src="https://…">`. Le
domaine est traité séparément (§9.4). L'ID doit être remappé précisément, sans
collision.

**Technique à deux passes (sentinelles)** — pour éviter tout risque qu'un nouvel ID
déjà substitué soit re-matché par un ID ancien traité plus tard dans le même batch :

```sh
# Passe 1 : old_id → jeton sentinelle unique
while IFS=$'\t' read -r old_id new_id post_type; do
  [ "$post_type" = "attachment" ] || continue
  wp --path="$SITE_B_WP_PATH" search-replace \
    "\"id\":${old_id}(?!\d)" "\"id\":__SITEGRAFT_${old_id}__" \
    --regex --precise --skip-columns=guid
  wp --path="$SITE_B_WP_PATH" search-replace \
    "wp-image-${old_id}(?!\d)" "wp-image-__SITEGRAFT_${old_id}__" \
    --regex --precise --skip-columns=guid
done < "$STATE_DIR/id-map.tsv"

# Passe 2 : jeton sentinelle → new_id réel
while IFS=$'\t' read -r old_id new_id post_type; do
  [ "$post_type" = "attachment" ] || continue
  wp --path="$SITE_B_WP_PATH" search-replace \
    "__SITEGRAFT_${old_id}__" "${new_id}" --precise --skip-columns=guid
done < "$STATE_DIR/id-map.tsv"
```

Les jetons sentinelles garantissent qu'aucune substitution de la passe 2 ne peut être
re-matchée par une règle de la passe 1 restée à exécuter (impossible, les deux passes
sont strictement séquentielles et disjointes par construction).

### 9.2 `post_parent`

`wordpress-importer` remappe déjà nativement `post_parent` (et le thumbnail féatured
image) en interne pendant l'import, via sa propre table de correspondance construite
pendant le run — **à condition que le post parent soit inclus dans le même import**
(voir §11 « hiérarchies de pages profondes »). `verify` vérifie qu'aucun
`post_parent` de B ne pointe vers un ID qui n'existe pas côté B (orphelin) ; en cas
d'orphelin détecté, un remap explicite via `id-map.tsv` est proposé en correction
manuelle (pas automatique — ce cas signale une erreur de sélection dans le manifest).

### 9.3 `page_on_front` / `show_on_front`

`page_on_front` sur A contient l'ID **de A** d'une page. Un simple `wp option update`
copierait cet ID tel quel sur B — faux. Traité comme un remap dédié dans
`core_wp_post_import` (hook du module `core-wp`, pas un cas générique du cœur) :

```sh
core_wp_post_import() {
  state_dir="$1"; id_map_tsv="$2"; wp_cmd_b="$3"
  old_front_id=$(cat "$state_dir/option-page_on_front.value" 2>/dev/null || echo "")
  [ -n "$old_front_id" ] || return 0
  new_front_id=$(awk -F'\t' -v old="$old_front_id" '$1==old{print $2}' "$id_map_tsv")
  [ -n "$new_front_id" ] && $wp_cmd_b option update page_on_front "$new_front_id"
}
```

### 9.4 Search-replace de domaine A→B

Deux passes obligatoires (variante brute et variante JSON-échappée, Etch stocke des
blobs JSON dans certaines options/postmeta) :

```sh
wp --path="$SITE_B_WP_PATH" search-replace 'https://a.example.com' 'https://b.example.com' \
  --skip-columns=guid --precise
wp --path="$SITE_B_WP_PATH" search-replace 'https:\/\/a.example.com' 'https:\/\/b.example.com' \
  --skip-columns=guid --precise
```

`--skip-columns=guid` : le `guid` WordPress n'est pas censé changer après création,
laisser wp-cli/l'import gérer sa valeur nativement plutôt que le réécrire à la main.

## 10. Harnais de test DDEV

`tests/integration/ddev-harness.sh` orchestre :

1. `ddev config` + `ddev start` pour deux projets jetables (site "A" et site "B"),
   WP core installé via `wp core install`.
2. **Seed A** (`fixtures/site-a-seed.sh`) : un mu-plugin jetable enregistre les CPTs
   `etch_cfs`/`etch_cpts`/`etch_loops` (nécessaire pour que `--post_type=` de `wp
   export` les reconnaisse), puis seed du contenu factice (`wp post create`) et des
   options factices (`wp option update etch_settings '...' --format=json`) — **sans
   licence Etch réelle**, uniquement la forme des données (CPTs + options),
   suffisante pour tester la mécanique de migration.
3. **Seed B** (`fixtures/site-b-fake-plugin/fake-plugin.php`) : faux plugin mu-plugin
   déposé sur B, enregistre un CPT `fakebooking_reservation`, crée une table
   `{$prefix}fakebooking_reservations` via `dbDelta`, seed quelques lignes + une
   option `fakebooking_settings`.
4. Snapshot checksums des données protégées de B (avant tout run sitegraft).
5. Run complet : `sitegraft scan/plan/backup/graft/verify --profile ddev-test`
   (le `plan` interactif est piloté en mode non-interactif via un manifest
   pré-rempli passé en argument, pour automatiser le test).
6. **Assertion centrale** : recalcul des checksums des données protégées de B,
   comparaison byte-identique au snapshot de l'étape 4.
7. Assertion secondaire : le contenu migré d'A est bien présent et rendu sur B.
8. `sitegraft restore` puis nouvelle comparaison : B revient exactement à son état
   pré-graft (design ET données protégées).
9. `trap` de teardown : `ddev delete -O` sur les deux projets, qu'il y ait succès ou
   échec — rien de persistant ne doit survivre à un run de test.

## 11. Edge cases

| Cas | Comportement sitegraft |
|-----|------------------------|
| CPT avec référence d'ID interne en postmeta (ex. « produit lié ») | Hors remap générique du cœur — c'est le rôle du hook `<mod>_post_import` du module concerné (exemple complet en §3.4). |
| Doublons de slugs entre contenu existant de B et contenu importé | WordPress gère nativement (suffixe `-2` automatique à l'insertion). `verify` diffe `post_name` A vs B post-import et **avertit** (pas un échec dur) si des slugs ont été renommés — signal pour vérifier les liens internes à la main. |
| `page_on_front` / `show_on_front` | Remap dédié via `core_wp_post_import`, voir §9.3. |
| Hiérarchies de pages profondes | `plan` **valide** que si un post_type hiérarchique (`page`) est sélectionné, TOUS ses ancêtres potentiels le sont aussi (même post_type, migration totale ou rien) — un import partiel d'une hiérarchie n'est pas un cas supporté en v1 (YAGNI : sitegraft migre des post_types entiers, pas des sous-arbres). |
| Réimport idempotent | Chaque post importé par sitegraft porte `_sitegraft_source_id` (posé par le mu-plugin, §7). Avant tout import, `graft` liste et supprime (`wp post delete --force`) les posts des post_types sélectionnés portant cette meta d'un run précédent — un re-run ne duplique jamais. Distinct de l'étape `clean` (qui supprime le contenu **pré-existant original** de B, pas le contenu posé par sitegraft lui-même). |

## 12. Self-review (2026-08-19)

Passe de relecture faite par Rosalinde après rédaction complète :
- **Placeholders/TBD** : aucun trouvé — toutes les commandes wp-cli, formats de
  fichiers et exemples de code sont concrets et exécutables tels quels (une fois les
  placeholders `example.com`/`user@host` remplacés par de vraies valeurs de profil).
- **Contradictions internes** : none identifiée entre §6.4 (ordre médias avant WXR) et
  §8 (comportement par défaut de `wp import`) — cohérents.
- **Ambiguïté corrigée en cours de rédaction** : la distinction entre `clean`
  (contenu pré-existant de B) et la purge d'idempotence (contenu posé par sitegraft
  lui-même) n'était pas explicite dans le brief initial — clarifiée et documentée
  séparément en §6.6 et §11 pour éviter toute confusion dans le plan d'implémentation.
- **Risques** : consignés explicitement en §0.2 (R1-R4) plutôt que noyés dans le
  texte, pour que Nat les fasse trancher par Marcel sans avoir à les extraire elle-même.
