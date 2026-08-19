# ADR 0003 — Portabilité ciblée bash 3.2 (pas de tableaux associatifs)

**Date :** 2026-08-19 · **Statut :** proposé (décision Rosalinde, à valider Marcel)

## Contexte

Le mandat demande une portabilité « n'importe quel Mac ou PC, macOS + Linux/WSL »
avec des dépendances minimales, et demande explicitement de « décider et documenter »
la version de bash ciblée. macOS embarque bash 3.2 par défaut (dernière version sous
licence GPLv2, Apple n'a jamais mis à jour vers bash 4+ sous GPLv3). Le système de
registre de modules (§3 du design doc) aurait naturellement utilisé un tableau
associatif (`declare -A`) — disponible seulement depuis bash 4.

## Décision

sitegraft cible la compatibilité bash 3.2. Aucune associative array, aucun `mapfile`,
aucun `${var,,}` (lowercase natif bash 4+). Le registre de modules est une simple
chaîne de noms séparés par espace, parcourue avec un `for` classique ; la présence
d'une fonction de module optionnelle est testée avec `type -t`.

## Conséquences

- (+) Tourne sans rien installer de plus sur un Mac fraîchement sorti de la boîte.
- (+) Cohérent avec l'esprit « dépendances minimales » du mandat.
- (−) Style de code légèrement plus verbeux par endroits (pas de sucre syntaxique
  bash 4+) — accepté, documenté dans `CLAUDE.md` du projet comme convention de code.
- (−) Si l'outil grossit beaucoup (dizaines de modules), l'absence de tableau
  associatif pourrait devenir gênante — non applicable en v1 (3 modules), à réévaluer
  si le nombre de modules dépasse ce que des listes plates gèrent confortablement.
