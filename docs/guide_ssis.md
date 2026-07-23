# Documentation ETL - ProductiviteDM_ETL (SSIS)

Description de la chaîne d'alimentation du data mart `PRODUCTIVITE_DM` : solution
SSIS à deux packages, chargements idempotents (reset en tête de package).
Les requêtes d'extraction sont dans `sql/02_sources_dimensions.sql` (dimensions)
et `sql/03_sources_faits.sql` (faits).

> Les packages `.dtsx` ne sont pas versionnés : ils contiennent la chaîne de
> connexion réelle. Seuls les scripts SQL et cette documentation sont publiés.

---

## Connexions

Deux gestionnaires de connexions OLE DB, définis au niveau projet :

| Nom | Cible |
|---|---|
| `SRC_COREBANKING` | base source (core banking, production) |
| `DST_PRODUCTIVITE_DM` | data mart `PRODUCTIVITE_DM` |

## Package 1 - `01_Load_Dimensions.dtsx`

| # | Tâche | Type | Contenu |
|---|---|---|---|
| 1 | Reset complet | Execute SQL Task (DST) | Bloc **A** de `04_reset_data_mart.sql` |
| 2 | Calendrier | Execute SQL Task (DST) | Bloc **A** de `02_sources_dimensions.sql` (2018-01-01 → 2024-12-31) |
| 3 | DIM_AGENCE | Data Flow (SRC → DST) | Bloc **B** ; libellés d'agence anonymisés à la source |
| 4 | DIM_GESTIONNAIRE | Data Flow | Bloc **C** ; anonymisation en libellés neutres. `GEST_ID` = IDENTITY, non mappé |
| 5 | DIM_PRODUIT | Data Flow | Bloc **D** (union crédit + épargne + pseudo-produit `EPM`). `PRODUIT_ID` = IDENTITY, non mappé |

L'ordre 3 → 4 est imposé par la clé étrangère de `DIM_GESTIONNAIRE` vers `DIM_AGENCE`.

## Package 2 - `02_Load_Faits.dtsx`

| # | Tâche | Contenu |
|---|---|---|
| 1 | Reset des faits | Bloc **B** de `04_reset_data_mart.sql` |
| 2 | FACT_ADHESION | Bloc **E** de `03_sources_faits.sql` |
| 3 | FACT_EPARGNE | Bloc **F** |
| 4 | FACT_PRODUCTION_CREDIT | Bloc **G** |
| 5 | FACT_REVENU | Bloc **H** |

Les quatre flux de données sont indépendants (les dimensions sont déjà chargées)
et peuvent donc être exécutés en séquence ou en parallèle après le reset.

### Résolution des clés de substitution

Les clés de substitution sont résolues par des lookups SSIS, pas dans le SQL :

| Flux | Lookups |
|---|---|
| FACT_ADHESION | `COD_GEST` → `GEST_ID` |
| FACT_EPARGNE | colonne dérivée `FAMILLE = "EPARGNE"`, puis lookup à deux colonnes (`FAMILLE`, `COD_PRODUIT`) → `PRODUIT_ID` |
| FACT_PRODUCTION_CREDIT | `COD_GEST` → `GEST_ID` ; colonne dérivée `FAMILLE = "CREDIT"`, puis (`FAMILLE`, `COD_PRDT_CRD`) → `PRODUIT_ID` |
| FACT_REVENU | aucun (mapping direct) |

Les lookups sont configurés en échec sur non-correspondance : les rares
`COD_GEST` orphelins sont rerouté en amont, dans les requêtes sources, vers un
membre inconnu de `DIM_GESTIONNAIRE` (pattern Kimball du *unknown member*), et
les autres référentiels ont été contrôlés sans orphelin. Un échec signalerait
donc une véritable anomalie de données, pas un cas normal à contourner.

## Contrôles de chargement

Volumétries de référence, à confronter après exécution :

| Table | Attendu |
|---|---|
| DIM_CALENDRIER | 2 557 lignes (7 années) |
| DIM_PRODUIT | 98 (81 crédit + 16 épargne + pseudo-produit EPM) |
| FACT_ADHESION | ~37 400 adhésions (somme de `NB_ADHESIONS`) |
| FACT_PRODUCTION_CREDIT | ~225 500 prêts, ~119,7 Md FCFA décaissés |
| FACT_REVENU | intérêts encaissés 2023 ≈ 2 128 M FCFA |

Le script `sql/05_reconciliation_hdpm.sql` complète ces contrôles en confrontant
les revenus du data mart à la comptabilité générale.

## Points d'attention

- Le flux `FACT_REVENU` interroge le journal comptable (plusieurs dizaines de
  millions de lignes) : sa durée d'exécution est sensiblement plus longue que
  celle des autres flux.
- Types attendus côté destination : `DATE_MOIS_ID` en entier (`DT_I4`), montants
  en `money` (`DT_CY`). Forcer le type dans l'éditeur avancé de la source si
  l'inférence automatique diverge.
- La direction générale figure au référentiel des agences ; elle est exclue des
  classements par agence au niveau des visuels.
