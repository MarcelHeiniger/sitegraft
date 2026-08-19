# ADR 0002 — Manifest en JSON, parsé via `jq`

**Date :** 2026-08-19 · **Statut :** proposé (décision Rosalinde, à valider Marcel)

## Contexte

Le manifest produit par `plan` et consommé par `graft` doit représenter une
structure imbriquée : par module, une liste de post_types, une liste d'option_keys,
une liste de tables, plus un bucket `_unclaimed` de défaut-deny et des checksums
calculés après coup par `backup`. Un format KEY=VALUE plat (à la manière des profils)
ne représente pas proprement cette imbrication sans conventions de nommage fragiles
(`MIGRATE_ETCH_POST_TYPES="a b c"`, etc.).

## Décision

Le manifest est un fichier JSON, lu et écrit exclusivement via `jq` dans `lib/manifest.sh`.

## Conséquences

- (+) Structure imbriquée native, lisible, versionnable, diffable proprement en git
  (utile si un manifest de référence est un jour commité pour un test).
- (+) `jq` est quasi-universel (`brew install jq`, `apt install jq`, déjà présent sur
  beaucoup de machines de dev).
- (−) Nouvelle dépendance runtime obligatoire (pas seulement de test) — à ajouter à la
  liste de préflight (`sitegraft` doit vérifier sa présence et échouer proprement avec
  un message d'installation sinon).
- (−) Manipuler du JSON en bash reste plus verbeux que des variables shell — accepté
  comme coût raisonnable vu la structure du problème.
