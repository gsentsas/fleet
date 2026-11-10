# GST FLEETBASE — RC1 Laravel 12 / PHP 8.2.35

> **DRAFT — PRODUCTION NO-GO.** Tableau de traçabilité, pas un feu vert de publication. Ce dossier ne contient aucun `composer.lock` approuvé et ne modifie pas les fichiers applicatifs.

## Références figées au 10 novembre 2026

| Composant | SHA RC1 | État |
|---|---|---|
| Core API | `f81cf74e38f9c11d03d0da6d6bdc9a489c7a52dd` | Nouveau : 3 corrections récupérées ; **tests RC1 encore à rejouer** ; [PR DRAFT #2](https://github.com/gsentsas/core-api/pull/2) |
| FleetOps | `665e4fdf16f0344a24a273ebd1599b92ba6c2728` | Identique à la preuve R12 ; inclut anti-rejeu + migrations Laravel12 ; [PR DRAFT #4](https://github.com/gsentsas/fleetops/pull/4) |
| Storefront | `b6d596154370ed5770225d889363a74fab56e584` | Identique à la preuve R12 ; migrations UUID ; [PR DRAFT #2](https://github.com/gsentsas/storefront/pull/2) |

Les SHA sont également enregistrés dans [fork-pins.json](fork-pins.json). Ne pas pinner les seuls noms de branches dans un manifeste Composer.

## Acquis vérifiés — NE PAS REFAIRE À L'IDENTIQUE

| Gate | Preuve | Statut |
|---|---|---|
| Graphe Composer Laravel12 / PHP 8.2 avec les trois forks R12 | [Fleet CI run 42587750098](https://github.com/gsentsas/fleet/actions/runs/42587750098) | PASS sur **ancien Core** `1b24680` |
| Audit du **lock candidat jetable** R12 sans exception | Même run | 0 avis relevé au moment du run |
| Installation candidat, autoload, contrats géocodage/FCM/FastPaginate | Même run | PASS, runner jetable |
| Tests API hôte | Même run | 44 tests / 120 assertions PASS |
| Découverte et catalogue des routes | Même run | 1 839 routes PASS |
| MySQL8 : 395 migrations, 3 bases vierges, schémas identiques, rerun idempotent | Même run | PASS ; 186 tables / 3 462 colonnes / 1 623 index / 410 FK |
| Ledger anti-rejeu FleetOps MySQL8 avec concurrence et effets exactement-une-fois | Même run | PASS, 8 workers |
| Core PHP 8.2.35+BCMath / lock isolé S12G / audit S12H / no-dev S12I / dev S12J | [Issue #1](https://github.com/gsentsas/fleet/issues/1) | PASS **sur Core historique S4**, distinct du RC1 |
| Tests Core restaurés S12K–S12N | [Issue #1 — S12N](https://github.com/gsentsas/fleet/issues/1#issuecomment-6762383123) | 209 tests / 1 268 assertions / 23 fichiers PASS sur Core `1b24680` |
| Sauvegardes opérationnelles, offsite B2, MFA admin, contrôles G0/G1/G4 | [Issue #1](https://github.com/gsentsas/fleet/issues/1) | Déjà contrôlés sur déploiement actuel, **pas sur RC1** |

## Correctifs Core historiques à consolider

**Déjà intégrés dans Core RC1 (mais pas encore testés sur ce nouveau SHA)** : promotion `cknow/laravel-money:v8.5.0` en dépendance runtime, deux gardes des dates invalides `ReportQueryExporter`, conversion TTL `Expirable` vers entier (Carbon3). Voir [Core PR #2](https://github.com/gsentsas/core-api/pull/2).

**Encore à réconcilier, sans application automatique** : `ActionMapper::getFromRequest()` et `DatabaseBackupService::dump()` (preuves historiques R13-A15J-R2 : 95 tests / 481 assertions PASS en labo différent), autres correctifs PHP 8.2 et dépréciations `utf8_decode` / `fputcsv`, 11 fichiers historiquement exclus. Vérifier chaque delta sur le SHA exact avant de porter ou rejouer.

## Blockers de publication (gates non acquis sur RC1)

1. **Monorepo root non mis à jour** : `api/composer.lock` de `main` reste un lock Laravel 10 avec **21 avis sur 10 paquets et un paquet abandonné** (audit du 09/11). Ne jamais le remplacer par le lock Core isolé S12G ; il faut résoudre puis **committer** le lock réel de l'application Fleetbase sur une branche séparée, avec les trois SHA RC1 épinglés.
2. **Nouveau Core SHA `f81cf74e`** : invalide la stricte équivalence avec la preuve CI centrale R12 et les campagnes S12K–N. Refaire **uniquement les tests affectés et les tests d'intégration pertinents** (Money/Export/TTL, puis ABI/autoload/compatibilité du monorepo). Ne pas annoncer les 209 anciens tests comme nouveaux PASS de cette PR.
3. **PR FleetOps/Storefront empilées** : conserver la généalogie FleetOps #1→#3→#4 et Storefront #1→#2 ; finaliser vérification code métier, API, IAM/IDOR et anti-rejeu sur l'artefact final.
4. **Exceptions et risques encore ouverts** : correctifs A15J, 11 exclusions, S12O 80 tests préparés **non exécutés**, audit final sans aucune dérogation ; ne pas masquer un avis Composer, ne pas considérer un workflow d'expérience « exit 1 » comme une CI de publication.
5. **Staging + rollback** : restauration/backup sur des données copiées, migrations de l'artefact réel, parcours Driver/TMS/Storefront et webhooks, supervision, preuve rollback. Pas de migration sur les bases actuelles avant GO.

## Ordre court de livraison

- **RC1A (en cours)** : PR Core #2 ; provenance des changements/traçabilité pin exacte, tests ciblés à passer.
- **RC1B (à exécuter)** : résoudre le **lock monorepo complet** à partir des trois forks épinglés, auditer strictement, committer le lock sur une branche expérimentale de RC, puis CI sur le SHA final ; aucun mélange avec main.
- **RC1C (à exécuter)** : compléter les tests manquants et statuer sur les correctifs historiques restant ; revue des PR empilées.
- **RC1D (à exécuter)** : staging isolé avec rollback ; présentation d'une décision finale GO/NO-GO.

**Stop final** : `RELEASE_DECISION=NO_GO`. Aucune fusion, aucun tag ni déploiement autorisé par ce document.
