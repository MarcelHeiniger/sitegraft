# ADR 0006 — `bats-core` pour les tests unitaires de `lib/`

**Date :** 2026-08-19 · **Statut :** proposé (décision Rosalinde, à valider Marcel)

## Contexte

Le mandat demande du TDD « là où ça a du sens — les fonctions pures de `lib/` sont
testables en bats », ce qui présuppose déjà bats sans le nommer explicitement comme
dépendance. Il fallait néanmoins acter le choix précis de framework et sa portée
(unitaire uniquement, l'intégration restant sur le harnais DDEV).

## Décision

`bats-core` pour tous les tests unitaires de `tests/unit/*.bats`, ciblant les
fonctions pures de `lib/` (parsing, validation, formatage — tout ce qui ne touche ni
SSH ni wp-cli ni le système de fichiers d'un vrai site). Dépendance de test
uniquement, jamais requise à l'exécution normale de l'outil.

## Conséquences

- (+) Framework standard pour tester du bash, syntaxe déclarative proche de tests
  unitaires classiques (`@test "description" { ... }`), bonne intégration avec
  `set -euo pipefail`.
- (+) Sépare clairement ce qui est testable vite (fonctions pures, `bats`) de ce qui
  nécessite le harnais DDEV complet (tout ce qui touche à un vrai site WordPress).
- (−) Nouvelle dépendance de développement (`brew install bats-core` /
  `npm install -g bats` / clone du repo) — sans impact sur l'utilisateur final de
  l'outil, seulement sur qui contribue au code.
