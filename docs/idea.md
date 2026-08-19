# Idée & vision — sitegraft

## Problème

Marcel refond régulièrement des sites WordPress existants en Etch/ACSS. Le site cible
(« B ») est souvent déjà en production avec un plugin métier chargé de données réelles
non-négociables (ex. un plugin de réservation avec des réservations clients live). La
refonte ne doit remplacer QUE la couche design/contenu (thème, pages, templates,
navigation, styles) — jamais toucher aux données ni à la configuration du plugin
métier de B. Aujourd'hui ce geste se fait à la main, site par site, sans outillage :
lent, non reproductible, et risqué (une erreur de search-replace ou d'export SQL brut
peut corrompre les données de production d'un client).

## Solution / proposition de valeur

sitegraft est un CLI bash qui encapsule ce geste en phases séparées, inspectables et
rejouables : scanner les deux sites, décider précisément quoi migrer et quoi protéger,
sauvegarder B avant toute modification, exécuter le transfert via les mécanismes
natifs de WordPress (WXR + wp-cli, jamais de SQL brut filtré à la main pour le
contenu), vérifier le résultat, et permettre un retour arrière en un clic. Le système
de modules enfichables rend chaque nouveau plugin métier (MotoPress aujourd'hui,
autre chose demain) une simple déclaration de fichier, sans toucher au cœur de
l'outil — donc directement réutilisable sur toutes les futures migrations Etch de
Marcel, quel que soit le plugin protégé côté B.

## Cible / utilisateurs

- **Utilisateur unique actuel : Marcel**, en tant qu'opérateur de migrations Etch pour
  ses propres projets et ceux de ses clients (agences, sites vitrine, sites métier).
- Pas de multi-utilisateur, pas de SaaS, pas d'UI web : un outil personnel outillé
  comme un vrai produit interne, publié en open-source pour la visibilité (repo public)
  mais sans ambition commerciale à ce stade.

## Scope

**Dans le périmètre :**
- Migration site A (Etch/ACSS fraîchement construit) → site B (existant, vivant),
  un run à la fois, une paire de sites à la fois.
- Modules de protection/migration pour WordPress core content + Etch + ACSS dès v1 ;
  extensible par fichier pour tout futur plugin métier.
- Backup complet de B avant toute écriture, restore en un script.
- Exécution locale (Mac/Linux/WSL) pilotant A et B à distance via SSH/wp-cli, ou en
  local via DDEV.
- Validation par harnais de test DDEV (2 sites jetables), pas de run pilote en
  production planifié pendant la construction de l'outil.

**Hors périmètre (explicitement) :**
- Pas de MCP, pas de web-UI, pas de plugin WordPress installé sur A ou B.
- Pas de support multi-site batch (une paire A→B par run).
- Pas de support Windows natif (WSL oui, cmd/PowerShell natif non).
- Pas de migration de plugins tiers eux-mêmes (seulement protection de leurs données) —
  sitegraft ne installe/configure jamais un plugin métier sur B.
- Pas de synchronisation continue / bidirectionnelle : sitegraft fait un transfert
  ponctuel A→B, pas une réplication.

## Contexte & historique

Né d'un brainstorming avec Marcel le 2026-08-19, motivé par le cas concret d'un site B
tournant MotoPress Hotel Booking en production avec des réservations live. Toutes les
décisions d'architecture (nom, approche CLI bash modulaire, base WXR/wp-cli, système
de modules, phases séparées, sélection interactive, stratégie de backup, mapping
d'ID via mu-plugin temporaire, portabilité) ont été actées avant la rédaction du
design doc — voir `docs/superpowers/specs/2026-08-19-sitegraft-design.md` pour le détail
et le raisonnement complet.
