# Todo — sitegraft

> Backlog courant. Priorisé. Reflète l'état live (API tâches) après chaque « update le projet ».
> **Dernière sync : 2026-08-19**

## Prochaines étapes (prioritaires)

- [ ] GO Marcel sur les 5 décisions techniques ouvertes (`docs/status.md` → Décisions récentes)
- [ ] Démarrer étape 1 du plan : core + profils/credentials + scan
      (`docs/plans/2026-08-19-sitegraft-implementation.md`)
- [ ] Étape 2 : manifest + sélection interactive (`gum choose`, fallback `fzf`)
- [ ] Étape 3 : backup + restore
- [ ] Étape 4 : graft (médias → WXR import → mu-plugin mapping → remaps)
- [ ] Étape 5 : verify + harnais d'intégration DDEV
- [ ] Étape 6 : polish (dry-run partout, `docs/usage.md`, LICENSE, README public anglais)

## Backlog

- [ ] Module hypothétique `motopress.sh` — écrit comme exemple pédagogique dans le
      design doc, pas encore implémenté ni testé contre un vrai MotoPress
- [ ] `docs/usage.md` détaillé (au-delà du README) si le README devient trop long
- [ ] Script d'installation (`install.sh` ou instructions Homebrew/apt pour les
      dépendances : `jq`, `gum`, `rsync`, `bats-core`)

## Idées / plus tard

- Support d'un mode "diff report" en sortie de `verify` (HTML ou markdown) — YAGNI pour
  la v1, à réévaluer une fois l'outil utilisé sur un vrai run
- Publication éventuelle sur Homebrew (`brew install sitegraft`) si l'outil sert au-delà
  de Marcel — hors scope v1

## Fait récemment

- [x] Design doc + plan d'implémentation + skeleton livrés (2026-08-19, Rosalinde)
