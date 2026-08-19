# ADR 0005 — Mu-plugin de mapping livré par dépôt de fichier, pas par `wp plugin install`

**Date :** 2026-08-19 · **Statut :** proposé (décision Rosalinde, à valider Marcel)

## Contexte

Le mandat demande un mu-plugin temporaire sur B pour logger le mapping d'ID pendant
l'import WXR (voir design doc §7). Deux façons de le poser : (a) comme un vrai plugin
WordPress installé via `wp plugin install`/`wp plugin activate`, ou (b) comme un
« must-use plugin » — un fichier PHP simplement déposé dans `wp-content/mu-plugins/`,
que WordPress charge automatiquement sans activation.

## Décision

Dépôt de fichier via `rsync` dans `wp-content/mu-plugins/`. Retiré par suppression du
même fichier en fin de phase `graft`.

## Conséquences

- (+) Aucun état d'activation à gérer côté wp-cli — un mu-plugin présent est chargé,
  un mu-plugin absent ne l'est pas. Pas de risque de « plugin resté activé » si le run
  crash au milieu.
- (+) Un seul fichier à transférer et à supprimer — geste simple, facile à rendre
  idempotent et à vérifier dans `verify`/nettoyage post-crash.
- (−) Les mu-plugins ne supportent pas nativement les hooks d'activation/désactivation
  WordPress classiques (`register_activation_hook`) — sans conséquence ici puisque le
  mu-plugin n'a besoin que de s'accrocher à `wp_import_insert_post`, qui se déclenche
  dès que le fichier est présent pendant l'import.
- (−) Si `wp-content/mu-plugins/` n'existe pas encore sur B (rare mais possible sur une
  install très minimale), `graft` doit le créer avant le `rsync` — noté comme
  pré-requis dans le plan d'implémentation.
