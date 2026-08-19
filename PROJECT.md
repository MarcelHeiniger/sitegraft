# sitegraft — Dossier projet

> **POINT D'ENTRÉE.** Ce fichier + les liens ci-dessous contiennent **tout** ce qu'il faut
> pour reprendre ce projet. Un dev externe qui dézippe ce dossier n'a **rien** à chercher
> ailleurs (ni vault, ni API, ni Slack) : idée, infra, status, todo, definition of done.
>
> **STATUS : idée (design + plan livrés, implémentation pas commencée)**
> **Dernière mise à jour : 2026-08-19** (par « update le projet »)

---

## 1. En une ligne

CLI bash portable qui « greffe » la couche design/contenu d'un site WordPress Etch/ACSS
fraîchement construit (site A) sur un site cible vivant (site B), sans jamais toucher
aux plugins/données métier de B — pour toute future migration Etch, projet-agnostique.

## 2. Idée & vision

Marcel construit régulièrement des refontes de sites WordPress en Etch/ACSS pour des
clients dont le site en production tourne déjà avec un plugin métier chargé de données
réelles (ex. réservations, e-commerce). Le remplacement manuel du thème/contenu sans
toucher aux données du plugin est répétitif, risqué et non outillé. sitegraft encapsule
ce geste dans un outil testé, rejouable, et extensible par simple ajout de fichier.
→ Détail : [`docs/idea.md`](docs/idea.md)

## 3. Infrastructure

Outil 100% local/portable : bash + wp-cli + ssh/rsync. Pas de service hébergé, pas de
base de données propre à l'outil. État de run stocké sur la machine qui exécute
l'outil (l'« orchestrateur »), jamais sur A ni B de façon permanente. **SANS secrets.**
→ Détail : [`docs/infrastructure.md`](docs/infrastructure.md)
→ Accès/creds : **jamais ici** — pointeurs dans `../.credentials/` (break-glass `~/.SuperUser/`).

## 4. Où en est le projet (status)

Design doc et plan d'implémentation livrés le 2026-08-19 (Rosalinde). Aucune ligne de
code de l'outil n'existe encore — seuls le skeleton projet et la documentation sont en
place. Aucun run pilote prévu : validation exclusivement par le harnais de test DDEV
(2 sites WP jetables) décrit dans le design doc.
→ Détail : [`docs/status.md`](docs/status.md)

## 5. Ce qui reste à faire (todo)

- [ ] Valider le design doc et les 5 décisions ouvertes avec Marcel (voir `docs/status.md` → Décisions récentes)
- [ ] Étape 1 du plan : core + profils/credentials + scan (voir `docs/plans/2026-08-19-sitegraft-implementation.md`)
- [ ] Étape 2 : manifest + sélection interactive
- [ ] Étape 3 : backup + restore
- [ ] Étape 4 : graft (médias + WXR + mu-plugin mapping + remaps)
- [ ] Étape 5 : verify + harnais d'intégration DDEV
- [ ] Étape 6 : polish (dry-run partout, docs usage, LICENSE, README public)
→ Détail : [`docs/todo.md`](docs/todo.md)

## 6. Definition of Done

Un run complet `scan → plan → backup → graft → verify` réussit sur le harnais DDEV
(site A avec contenu Etch simulé, site B avec un faux plugin protégé) sans altérer un
seul octet des données du faux plugin de B, avec `restore.sh` fonctionnel et testé.
→ Détail : [`docs/definition-of-done.md`](docs/definition-of-done.md)

## 7. Démarrer (dev)

Voir [`README.md`](README.md) — install / build / test / lancer en local.

## 8. Historique des décisions

[`docs/decisions/`](docs/decisions/) — une décision = un fichier (ADR « pourquoi X »).
Plans d'implémentation : [`docs/plans/`](docs/plans/).
Design doc complet : [`docs/superpowers/specs/2026-08-19-sitegraft-design.md`](docs/superpowers/specs/2026-08-19-sitegraft-design.md).

---

### Convention de mise à jour

Ce dossier est **la source de vérité** du projet. Quand Marcel dit **« update le projet »** :
Nat pull l'état live (API tâches + travail de la session), réconcilie, et réécrit
les sections 4-5-6 + la date ci-dessus. Le dossier est **toujours zip-ready** ensuite.

### Note visibilité repo

`repo/` est destiné à être publié en **repo GitHub public** (compte MarcelHeiniger,
exception à la convention « tous les repos privés »). Conséquence stricte : **zéro
secret, zéro host/IP réel, zéro nom de client, pas même d'exemple « réaliste »** —
uniquement des placeholders génériques (`example.com`, `user@host`, `<profile>`).
Le README.md à la racine de `repo/` est en anglais et public-facing ; les docs projet
internes (ce fichier, `docs/`) restent en français.
