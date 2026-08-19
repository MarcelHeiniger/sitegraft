# ADR 0001 — CLI bash modulaire à phases séparées

**Date :** 2026-08-19 · **Statut :** accepté

## Contexte

Marcel refond régulièrement des sites WordPress Etch/ACSS et doit répéter, à la main,
le remplacement de la couche design/contenu d'un site cible vivant sans toucher aux
données de ses plugins métier. Plusieurs architectures étaient possibles : un plugin
WordPress installé sur le site cible, une application web (MCP/UI), ou un CLI
autonome piloté depuis une machine tierce.

## Décision

sitegraft est un CLI bash pur (pas de Python/Node, pas de plugin WordPress, pas de
web-UI, pas de MCP), organisé en phases indépendantes et re-exécutables
(`scan → plan → backup → graft → verify → restore`), avec un système de modules
enfichables par fichier pour déclarer ce qui doit être migré vs protégé selon le
plugin métier présent sur le site cible.

## Conséquences

- (+) Aucune installation persistante sur A ou B — l'outil ne laisse aucune trace une
  fois le run terminé (hors le mu-plugin temporaire, retiré en fin de `graft`).
- (+) Chaque phase est inspectable et rejouable indépendamment — un `graft` interrompu
  ne force pas à recommencer un `scan`/`plan`/`backup` déjà faits.
- (+) Le système de modules rend l'outil réutilisable sur toute future migration Etch,
  quel que soit le plugin métier du site cible, sans toucher au cœur.
- (−) Pas d'interface graphique — toute interaction reste en ligne de commande
  (`gum`/`fzf` pour l'aspect interactif), acceptable pour un usage opérateur unique.
- (−) La portabilité bash impose des contraintes de style de code (voir ADR 0003).
