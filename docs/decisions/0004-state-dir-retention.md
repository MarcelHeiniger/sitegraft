# ADR 0004 — State-dir de run : emplacement et rétention manuelle

**Date :** 2026-08-19 · **Statut :** proposé (décision Rosalinde, à valider Marcel)

## Contexte

Chaque run de sitegraft produit des artefacts sensibles à conserver au moins jusqu'à
vérification complète : manifest figé, table de correspondance d'ID, backup complet
de B, logs par phase. Il fallait décider où ces artefacts vivent sur la machine
orchestratrice, et si/quand ils sont nettoyés automatiquement.

## Décision

`~/.sitegraft/runs/<profile>-<timestamp>/` sur la machine orchestratrice. Aucun
nettoyage automatique — la suppression est un geste manuel de l'opérateur.

## Conséquences

- (+) Le backup d'un run reste disponible tant que l'opérateur ne l'a pas
  explicitement supprimé — pas de risque qu'un `restore.sh` pointe vers un backup
  déjà purgé automatiquement au mauvais moment.
- (+) Chaque run est isolé et horodaté, inspectable indépendamment.
- (−) Accumulation potentielle sur la durée si l'outil est utilisé souvent (backups
  complets de sites entiers) — pas de commande de purge en v1 (YAGNI, voir
  `docs/todo.md` → Idées/plus tard, un `sitegraft prune` pourrait être ajouté si le
  besoin se confirme).
- (−) Pas de garde-fou automatique contre un disque plein — à surveiller côté
  opérateur pour l'instant.
