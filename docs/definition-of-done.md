# Definition of Done — sitegraft

> Les critères objectifs qui disent « c'est fini ». Un dev externe doit pouvoir cocher
> cette liste et savoir sans ambiguïté si son travail est acceptable.

## DoD projet (v1 — outil utilisable pour un vrai run)

Le projet v1 est considéré livré quand :
- [ ] Les 6 phases (`scan`, `plan`, `backup`, `graft`, `verify`, `restore`) sont
      implémentées et exécutables individuellement en CLI (`sitegraft <phase> --profile <nom>`).
- [ ] Les 3 modules v1 (`core-wp`, `etch`, `acss`) fonctionnent de bout en bout sur le
      harnais DDEV.
- [ ] Un run complet `scan → plan → backup → graft → verify` réussit sur le harnais
      DDEV sans altérer un seul octet des données du faux plugin protégé de B
      (assertion byte-identique automatisée, pas visuelle).
- [ ] `restore.sh` généré par la phase `backup` restaure B dans l'état exact
      pré-`graft`, testé sur le harnais DDEV.
- [ ] `--dry-run` fonctionne sur toutes les phases qui écrivent (`backup`, `graft`,
      l'étape optionnelle `clean`, `restore`).
- [ ] Ajouter un nouveau module (ex. `motopress.sh` hypothétique documenté en exemple
      dans le design doc) ne nécessite la modification d'aucun fichier de `lib/` ou
      `bin/` — uniquement l'ajout d'un fichier dans `modules/`.
- [ ] Tests unitaires (`bats`) verts pour toutes les fonctions pures de `lib/`.
- [ ] Tests d'intégration DDEV verts (non-contamination des données protégées).
- [ ] `docs/usage.md` (ou section README) permet à quelqu'un qui ne connaît pas
      l'outil de lancer un premier run sans autre aide.
- [ ] Repo public GitHub prêt à publier : LICENSE MIT présente, README.md racine en
      anglais public-facing, zéro secret/host réel/IP/nom de client dans tout
      l'historique git (pas seulement le HEAD).

## DoD par tâche / PR (rappel)

Toute contribution doit :
- [ ] Passer les tests unitaires `bats` concernés (voir `infrastructure.md` → CI)
- [ ] Être testée en conditions réelles (DDEV pour tout ce qui touche `graft`/`backup`),
      pas seulement en lecture de code
- [ ] Ne pas régresser l'existant (relancer le harnais DDEV complet avant merge sur une
      tâche touchant `lib/`, `modules/`, ou une phase)
- [ ] Ne jamais introduire de SQL brut filtré à la main pour du contenu — uniquement
      WXR (`wp export`/`wp import`) pour le contenu, `wp option get/update` pour les
      options, `wp db export --tables=` ciblé pour les tables propres à un plugin
- [ ] Ne jamais utiliser `sed`/regex brute sur des données WordPress sérialisées —
      toujours `wp search-replace` (safe sur les données sérialisées PHP)
- [ ] Documenter tout changement de contrat de module dans le design doc
- [ ] Bumper la version dans `bin/sitegraft` (voir `../CLAUDE.md` → Conventions) si le
      changement touche le comportement utilisateur

## Critères d'acceptation spécifiques

- **Non-contamination :** toute donnée appartenant à un post_type, une option, ou une
  table déclarée par un module de protection sur B (c'est-à-dire présente sur B mais
  absente de la sélection de migration) doit être bit-for-bit identique avant et après
  `graft` — vérifié par checksum, pas par inspection visuelle.
- **Défaut sûr (default-deny) :** tout post_type/table/option détecté sur B mais non
  couvert par un module connu doit être listé comme « à protéger par défaut » et
  jamais touché sans sélection explicite dans le manifest.
- **Idempotence :** relancer `graft` avec le même manifest sur un B déjà greffé ne doit
  ni dupliquer le contenu ni corrompre l'état (voir design doc → edge case réimport).
- **Portabilité :** l'outil tourne sans modification sur macOS (bash système 3.2) et
  sur Linux/WSL (bash ≥ 4), sans dépendance à une machine ou un host précis.
