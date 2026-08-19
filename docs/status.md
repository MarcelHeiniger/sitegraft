# Status — sitegraft

**STATUS : idée**  <!-- idée → en construction → live/production → maintenance → archivé -->
**Dernière mise à jour : 2026-08-19** (via « update le projet »)

## Résumé

Le brainstorming avec Marcel est terminé (13 décisions actées, voir design doc §0).
Rosalinde a livré le design doc complet, le plan d'implémentation en 6 étapes, le
skeleton projet et la documentation de handoff. Aucune ligne de code de l'outil
lui-même n'existe encore. Rien ne bloque le démarrage de l'étape 1 du plan, sous
réserve de validation par Marcel des 5 décisions techniques prises seule par Rosalinde
(voir « Décisions récentes » ci-dessous) et de la précision arrivée en cours de tâche
sur la visibilité publique du repo (déjà intégrée dans tous les docs).

## Fait

- [x] Brainstorming complet avec Marcel (13 décisions actées, hors scope de réouverture)
- [x] Skeleton projet créé (`repo/` + `dist/` + `.credentials/`)
- [x] `PROJECT.md` + `docs/{idea,infrastructure,status,todo,definition-of-done}.md` rédigés
- [x] `CLAUDE.md` projet adapté
- [x] Design doc complet (`docs/superpowers/specs/2026-08-19-sitegraft-design.md`)
- [x] Plan d'implémentation en 6 étapes (`docs/plans/2026-08-19-sitegraft-implementation.md`)
- [x] Self-review du design doc (placeholders/contradictions/ambiguïtés)
- [x] ADR pour les décisions ouvertes (`docs/decisions/000x-*.md`)

## En cours

- [ ] Rien — en attente du GO de Marcel pour démarrer l'étape 1 du plan d'implémentation

## Bloqué / en attente

- Validation des 5 décisions techniques prises seule par Rosalinde (voir ci-dessous)
- GO Marcel pour créer le repo GitHub public (Nat s'en charge, pas Rosalinde)

## Décisions récentes

Décisions techniques prises seule pendant la conception, **à valider par Marcel**
(détail et justification dans le design doc §0 et les ADR correspondants) :
1. `jq` comme dépendance pour parser/écrire le manifest en JSON (structure imbriquée
   par module × post_types/option_keys).
2. Portabilité ciblée bash 3.2 (pas d'associative arrays) plutôt qu'exiger bash ≥ 4 —
   pour tourner sans modification sur macOS système.
3. Emplacement et rétention du state-dir de run : `~/.sitegraft/runs/<profile>-<timestamp>/`
   sur l'orchestrateur, jamais nettoyé automatiquement (à la charge de l'opérateur).
4. Mu-plugin de mapping livré par dépôt de fichier via `rsync` dans `wp-content/mu-plugins/`
   (auto-chargé par WordPress, pas d'activation wp-cli nécessaire) plutôt que par un
   mécanisme `wp plugin install`.
5. `bats-core` comme framework de test unitaire pour les fonctions pures de `lib/`.

Précision reçue en cours de tâche (déjà intégrée) : le repo sera publié en **GitHub
public** sous MarcelHeiniger — conséquences (zéro secret/exemple réaliste, LICENSE MIT,
README racine en anglais) répercutées dans tous les fichiers concernés.
