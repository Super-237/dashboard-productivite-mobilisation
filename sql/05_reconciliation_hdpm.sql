/*===============================================================================
  Projet : Portfolio Power BI - Productivite & mobilisation des ressources (EMF)
  Script : 05_reconciliation_hdpm.sql
  Objet  : Controle qualite : reconciliation des revenus du data mart
           (FACT_REVENU, optique encaissement) avec le journal comptable
           HDPM (classe 7, optique comptable).
  Usage  : a executer dans SSMS APRES le chargement SSIS, sur l'instance qui
           heberge les deux bases (requetes inter-bases). Lecture seule.
  Sortie : 3 jeux de resultats a analyser puis a resumer dans le README :
             R1. Vue globale par annee (mart vs comptabilite)
             R2. Detail par type de revenu mappe sur ses comptes
             R3. Ecarts en pourcentage

  ECARTS ATTENDUS (a documenter, pas a "corriger") :
   - Cash vs couru : le mart compte les encaissements (DATE_REMB), la compta
     reconnait les produits (facturation, creances rattachees CRRA,
     regularisations). Les deux optiques divergent en timing par construction.
   - Reclassements : l'institution a change des schemas d'imputation au fil
     des annees (ex. droits d'adhesion 755100 -> 719220 mi-2022). Le mapping
     ci-dessous suit les comptes concernes quand ils sont connus.
   - Perimetre : la classe 7 contient des produits hors productivite d'agence
     (76 subventions, 77 exceptionnels, 78/79 reprises) exclus du mart.
===============================================================================*/

USE PRODUCTIVITE_DM;
GO

/*-------------------------------------------------------------------------------
  R1. VUE GLOBALE PAR ANNEE
      Mart = total FACT_REVENU. Compta = classe 7 "productive" (70-75,
      hors 76/77/78/79), credits nets, hors ecritures de cloture.
-------------------------------------------------------------------------------*/
WITH mart AS (
    SELECT c.ANNEE, SUM(f.MONTANT_REVENU) AS revenu_mart
    FROM dbo.FACT_REVENU f
    JOIN dbo.DIM_CALENDRIER c ON c.DATE_ID = f.DATE_MOIS_ID
    GROUP BY c.ANNEE
),
compta AS (
    SELECT YEAR(h.DATE_OPERATION) AS ANNEE,
           SUM(CASE WHEN h.SENS_OPERATION = 'C'
                    THEN h.MONTANT_TRANS ELSE -h.MONTANT_TRANS END) AS produits_compta
    FROM CoreBanking_EMF.dbo.HDPM h
    WHERE LEFT(h.NUM_CPTE, 1) = '7'
      AND LEFT(h.NUM_CPTE, 2) NOT IN ('76','77','78','79')
      AND h.COD_TYP_OPERAT NOT IN ('REPR','INVT','RSLT')
      AND h.DATE_OPERATION >= '2018-01-01'
      AND h.DATE_OPERATION <  '2024-12-01'
    GROUP BY YEAR(h.DATE_OPERATION)
)
SELECT
    m.ANNEE,
    CAST(m.revenu_mart      / 1000000.0 AS decimal(12,1)) AS mart_M,
    CAST(c.produits_compta  / 1000000.0 AS decimal(12,1)) AS compta_M,
    CAST((m.revenu_mart - c.produits_compta) / 1000000.0 AS decimal(12,1)) AS ecart_M,
    CAST(100.0 * (m.revenu_mart - c.produits_compta)
         / NULLIF(c.produits_compta, 0) AS decimal(6,1)) AS ecart_pct
FROM mart m
JOIN compta c ON c.ANNEE = m.ANNEE
ORDER BY m.ANNEE;
GO

/*-------------------------------------------------------------------------------
  R2. DETAIL PAR TYPE DE REVENU
      Chaque type du mart est compare aux comptes comptables qui lui
      correspondent le plus directement. Mapping type -> comptes :
        1  Interets encaisses           <-> 711% a 714%, 7191% (hors 7190)
        2  Penalites encaissees         <-> 7190%
        4  Frais de dossier             <-> 71510,71520,71530,71540
        5  Frais de gestion             <-> 71511,71521,71531,71541
        7  Frais de tenue de compte     <-> 7200%
        9  Frais adhesion + ouverture   <-> 755100, 719220  (meme source :
                                            l'ecart doit etre ~0, c'est le
                                            temoin de sante du controle)
        10 Assurance-vie minimum        <-> 719240, 741701, 741702
      Types sans equivalent comptable univoque (3, 6, 8, 11) : non compares
      individuellement, ils restent couverts par la vue globale R1.
-------------------------------------------------------------------------------*/
WITH map_cpte AS (
    SELECT h.DATE_OPERATION, h.SENS_OPERATION, h.MONTANT_TRANS,
           CASE
             WHEN LEFT(h.NUM_CPTE,6) IN ('755100','719220')                   THEN 9
             WHEN LEFT(h.NUM_CPTE,5) IN ('71510','71520','71530','71540')     THEN 4
             WHEN LEFT(h.NUM_CPTE,5) IN ('71511','71521','71531','71541')     THEN 5
             WHEN LEFT(h.NUM_CPTE,4) = '7190'                                 THEN 2
             WHEN LEFT(h.NUM_CPTE,4) = '7191'                                 THEN 1
             WHEN LEFT(h.NUM_CPTE,3) IN ('711','712','713','714')             THEN 1
             WHEN LEFT(h.NUM_CPTE,4) = '7200'                                 THEN 7
             WHEN LEFT(h.NUM_CPTE,6) IN ('719240','741701','741702')          THEN 10
           END AS TYPE_REVENU_ID
    FROM CoreBanking_EMF.dbo.HDPM h
    WHERE LEFT(h.NUM_CPTE,1) = '7'
      AND h.COD_TYP_OPERAT NOT IN ('REPR','INVT','RSLT')
      AND h.DATE_OPERATION >= '2018-01-01'
      AND h.DATE_OPERATION <  '2024-12-01'
),
compta AS (
    SELECT TYPE_REVENU_ID, YEAR(DATE_OPERATION) AS ANNEE,
           SUM(CASE WHEN SENS_OPERATION = 'C'
                    THEN MONTANT_TRANS ELSE -MONTANT_TRANS END) AS compta
    FROM map_cpte
    WHERE TYPE_REVENU_ID IS NOT NULL
    GROUP BY TYPE_REVENU_ID, YEAR(DATE_OPERATION)
),
mart AS (
    SELECT f.TYPE_REVENU_ID, c.ANNEE, SUM(f.MONTANT_REVENU) AS mart
    FROM dbo.FACT_REVENU f
    JOIN dbo.DIM_CALENDRIER c ON c.DATE_ID = f.DATE_MOIS_ID
    WHERE f.TYPE_REVENU_ID IN (1,2,4,5,7,9,10)
    GROUP BY f.TYPE_REVENU_ID, c.ANNEE
)
SELECT
    t.TYPE_REVENU_ID,
    t.LIBELLE,
    m.ANNEE,
    CAST(ISNULL(m.mart,0)   / 1000000.0 AS decimal(12,1)) AS mart_M,
    CAST(ISNULL(co.compta,0)/ 1000000.0 AS decimal(12,1)) AS compta_M,
    CAST((ISNULL(m.mart,0) - ISNULL(co.compta,0)) / 1000000.0 AS decimal(12,1)) AS ecart_M
FROM mart m
JOIN dbo.DIM_TYPE_REVENU t ON t.TYPE_REVENU_ID = m.TYPE_REVENU_ID
LEFT JOIN compta co ON co.TYPE_REVENU_ID = m.TYPE_REVENU_ID AND co.ANNEE = m.ANNEE
ORDER BY t.TYPE_REVENU_ID, m.ANNEE;
GO

/*-------------------------------------------------------------------------------
  R3. TEMOIN DE SANTE : le type 9 doit etre a ecart nul (meme source HDPM).
      Un ecart ici signale un bug de chargement, pas une divergence metier.
-------------------------------------------------------------------------------*/
WITH mart9 AS (
    SELECT c.ANNEE, SUM(f.MONTANT_REVENU) AS mart
    FROM dbo.FACT_REVENU f
    JOIN dbo.DIM_CALENDRIER c ON c.DATE_ID = f.DATE_MOIS_ID
    WHERE f.TYPE_REVENU_ID = 9
    GROUP BY c.ANNEE
),
hdpm9 AS (
    SELECT YEAR(h.DATE_OPERATION) AS ANNEE,
           SUM(CASE WHEN h.SENS_OPERATION = 'C'
                    THEN h.MONTANT_TRANS ELSE -h.MONTANT_TRANS END) AS compta
    FROM CoreBanking_EMF.dbo.HDPM h
    WHERE LEFT(h.NUM_CPTE,6) IN ('755100','719220')
      AND h.COD_TYP_OPERAT NOT IN ('REPR','INVT','RSLT')
      AND h.DATE_OPERATION >= '2018-01-01'
      AND h.DATE_OPERATION <  '2024-12-01'
    GROUP BY YEAR(h.DATE_OPERATION)
)
SELECT m.ANNEE,
       CAST(m.mart   / 1000000.0 AS decimal(12,2)) AS mart_M,
       CAST(h.compta / 1000000.0 AS decimal(12,2)) AS compta_M,
       CAST((m.mart - h.compta) / 1000.0 AS decimal(12,1)) AS ecart_K,
       CASE WHEN ABS(m.mart - h.compta) < 1000 THEN 'OK' ELSE 'A INVESTIGUER' END AS verdict
FROM mart9 m
JOIN hdpm9 h ON h.ANNEE = m.ANNEE
ORDER BY m.ANNEE;
GO
