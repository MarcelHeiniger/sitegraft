# Infrastructure — sitegraft

> ⚠️ **SANITIZED — aucun secret ici.** Ce fichier part dans le zip remis à un externe
> ET dans un repo GitHub **public**. Pas de mot de passe, token, clé privée, host réel
> ni IP — même pas d'exemple « réaliste ». Uniquement `example.com`, `user@host`,
> `<profile>`. Les accès réels sont des **pointeurs** dans `../.credentials/` →
> break-glass `~/.SuperUser/<serveur>.md` (local, jamais commité, jamais dans ce repo).

## Stack technique

- **Langage :** bash pur, compatible bash 3.2 (macOS système) — voir
  `docs/decisions/0003-bash-compatibility.md`. Pas de Python, pas de Node, pas de plugin WP.
- **Dépendances runtime :** `ssh`, `rsync` (jamais `scp`), `wp-cli` (sur A, sur B, ou
  via wrapper `ddev wp`), `jq` (parsing du manifest JSON), `gum` (UI interactive,
  fallback `fzf`, fallback prompt texte brut).
- **Dépendances de test uniquement :** `bats-core` (tests unitaires des fonctions
  pures de `lib/`), `ddev` (harnais d'intégration à 2 sites jetables).
- **Aucune base de données propre à l'outil.** Toutes les données transitent par les
  bases WordPress de A et B eux-mêmes (via wp-cli).

## Où ça tourne

sitegraft n'est **pas hébergé** — c'est un outil qu'on exécute depuis n'importe quelle
machine (« l'orchestrateur ») disposant des dépendances runtime ci-dessus.

| Rôle | Description | Notes |
|------|-------------|-------|
| Orchestrateur | Machine (Mac/Linux/WSL) où `sitegraft` est lancé | État de run (`~/.sitegraft/runs/<id>/`) local à cette machine |
| Site A | Site WordPress Etch/ACSS source, joignable en SSH+wp-cli ou DDEV local | Read-only pour sitegraft (jamais modifié) |
| Site B | Site WordPress cible vivant, joignable en SSH+wp-cli ou DDEV local | Écrit uniquement pendant la phase `graft`, après backup |

Chaque paire A↔B réelle (hosts, chemins, alias SSH) est déclarée dans un fichier de
profil `profiles/<nom>.conf` — commitable, sans secret (uniquement des noms de
variables). Les credentials (clé SSH, mot de passe éventuel) vivent soit dans
`~/.config/sitegraft/<profile>.creds` (chmod 600, gitignored), soit sont saisis à la
volée. Voir le design doc §5 pour le détail exact des deux formats.

## Déploiement

sitegraft ne se « déploie » pas : c'est un CLI qu'on clone/installe (`git clone` +
`PATH`, ou copie de `bin/sitegraft` + `lib/` + `modules/`) sur la machine
orchestratrice. Pas de CI/CD de déploiement applicable.

## DNS / domaines

Sans objet — sitegraft ne gère ni ne modifie de DNS. Le domaine de B reste celui déjà
en place ; sitegraft fait uniquement un `wp search-replace` du domaine de A vers celui
de B **à l'intérieur du contenu importé** (voir design doc, remapping post-import).

## CI / tests

- **Tests unitaires** (`tests/unit/*.bats`) : fonctions pures de `lib/*.sh`, exécutables
  sans aucune dépendance externe autre que bats-core. Doivent être verts avant tout
  commit touchant `lib/`.
- **Tests d'intégration** (`tests/integration/`) : harnais DDEV à 2 sites jetables
  (A = contenu Etch simulé, B = faux plugin protégé + son CPT + sa table SQL).
  Assertion centrale : les données du faux plugin de B sont byte-identiques avant/après
  un run `graft` complet. Doivent être verts avant tout merge touchant `graft`/`backup`.
- Pas de CI hébergée planifiée pour ce projet à ce stade (outil personnel, pas de repo
  d'entreprise avec pipeline obligatoire) — `bats` + harnais DDEV se lancent en local
  avant commit/merge. À revoir si le repo public attire des contributions externes.

## Sauvegardes / restauration

C'est une fonctionnalité de l'outil lui-même (phase `backup`), pas une infra externe :
`wp db export` complet de B + `tar` de `wp-content`, rapatriés sur l'orchestrateur via
`rsync`, accompagnés d'un `restore.sh` généré et prêt à l'emploi. Détail complet dans
le design doc §7 (phase backup) et §8 (phase restore).
