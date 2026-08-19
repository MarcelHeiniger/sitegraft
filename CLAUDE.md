# CLAUDE.md — sitegraft (repo)

**Lis d'abord `PROJECT.md`** (point d'entrée : idée, infra, status, todo, DoD),
puis `docs/plans/` et `docs/status.md` avant toute action sur ce projet.

## Quoi

CLI bash portable qui greffe la couche design/contenu d'un site WordPress Etch/ACSS
(site A) sur un site cible vivant (site B) sans toucher aux plugins/données de B.

## Langue

- **Docs projet** (`PROJECT.md`, `docs/*.md` sauf `README.md` racine) : **français**.
- **README.md racine** (public-facing, repo GitHub public) : **anglais**.
- **Code et commentaires de code** (`bin/`, `lib/`, `modules/`, `tests/`) : **anglais**,
  y compris une fois l'implémentation commencée — convention à respecter dès le
  premier commit de code.

## Dev / build

Pas encore implémenté — voir `docs/plans/2026-08-19-sitegraft-implementation.md` pour
la marche à suivre. Une fois l'outil amorcé :
```sh
# tests unitaires (fonctions pures de lib/)
bats tests/unit/

# tests d'intégration (harnais DDEV à 2 sites jetables)
tests/integration/ddev-harness.sh
```

## Déploiement

Sans objet — sitegraft ne se déploie pas, c'est un CLI cloné/installé sur la machine
qui l'exécute (voir `docs/infrastructure.md`).

## Conventions

- **Versioning** : bump de version dans `bin/sitegraft` (variable `SITEGRAFT_VERSION`)
  à chaque changement de comportement utilisateur visible.
- **Jamais de SQL brut filtré à la main pour du contenu.** Contenu = WXR (`wp export`/
  `wp import`). Options = `wp option get/update --format=json` un par un. Tables
  propres à un plugin = `wp db export --tables=X,Y` ciblé.
- **Jamais de `sed`/regex brute sur des données WordPress.** Toujours `wp search-replace`
  (safe sur le PHP sérialisé).
- **Jamais `scp`.** Toujours `rsync` pour tout transfert de fichier.
- **Système de modules = le point d'extensibilité.** Un nouveau plugin métier à
  protéger = un nouveau fichier `modules/<plugin>.sh`, zéro modification de `lib/` ou
  `bin/`. Voir le design doc §3 pour le contrat exact.
- **Défaut sûr (default-deny).** Tout ce qui est détecté sur B mais non couvert par un
  module connu est protégé par défaut, jamais migré/écrasé sans sélection explicite.
- **Zéro secret dans le repo — repo public GitHub.** Aucun host réel, IP, mot de passe,
  token, nom de client, même pas en exemple « réaliste ». Uniquement des placeholders
  génériques (`example.com`, `user@host`, `<profile>`). Les credentials réels vivent en
  dehors du repo (`~/.config/sitegraft/<profile>.creds`, gitignored) ou sont saisis à
  la volée.
- **Portabilité bash 3.2** (pas d'associative arrays) — voir
  `docs/decisions/0003-bash-compatibility.md`.
