/*===============================================================================
  Projet : Portfolio Power BI - Productivite & mobilisation des ressources (EMF)
  Script : 02_sources_dimensions.sql
  Objet  : Requetes SOURCE pour le chargement des dimensions via SSIS.
  Usage  : - Bloc CALENDRIER  -> Execute SQL Task sur la connexion DESTINATION
                                  (PRODUCTIVITE_DM).
           - Blocs AGENCE / GESTIONNAIRE / PRODUIT -> a coller dans chaque
             OLE DB Source (mode "SQL command"), connexion SOURCE
             (CoreBanking_EMF).
  Note   : dimensions conformes avec PORTFOLIO_CREDIT_DM (memes requetes
           agence/gestionnaire, meme anonymisation GEST-XXX).
===============================================================================*/


/*-------------------------------------------------------------------------------
  A. DIM_CALENDRIER  (Execute SQL Task, connexion = PRODUCTIVITE_DM)
     Genere un calendrier 2018-01-01 -> 2024-12-31. Idempotent.
     Annees COMPLETES volontairement (dec. 2024 inclus dans le calendrier
     meme si les faits s'arretent a nov. 2024) : la time intelligence DAX
     (SAMEPERIODLASTYEAR, DATESYTD...) exige une table de dates sans trou
     couvrant des annees entieres (Russo/Ferrari).
-------------------------------------------------------------------------------*/
SET LANGUAGE French;

IF NOT EXISTS (SELECT 1 FROM dbo.DIM_CALENDRIER)
BEGIN
    ;WITH d AS (
        SELECT CAST('2018-01-01' AS date) AS dj
        UNION ALL
        SELECT DATEADD(day, 1, dj) FROM d WHERE dj < '2024-12-31'
    )
    INSERT INTO dbo.DIM_CALENDRIER
        (DATE_ID, DATE_JOUR, ANNEE, TRIMESTRE, MOIS, NOM_MOIS, ANNEE_MOIS, JOUR)
    SELECT
        CONVERT(int, CONVERT(char(8), dj, 112)) AS DATE_ID,   -- AAAAMMJJ
        dj,
        YEAR(dj),
        DATEPART(quarter, dj),
        MONTH(dj),
        DATENAME(month, dj),                                  -- mois en francais
        CONVERT(char(7), dj, 121),                            -- AAAA-MM
        DAY(dj)
    FROM d
    OPTION (MAXRECURSION 0);
END;


/*-------------------------------------------------------------------------------
  B. DIM_AGENCE  (OLE DB Source, connexion = CoreBanking_EMF)
     Mapping destination : COD_AGENCE, NOM_AGENCE, VILLE
     Identique au 1er mart (dimension conforme).
-------------------------------------------------------------------------------*/
-- ANONYMISATION (portfolio public) : on n'expose ni les vrais noms d'agence ni
-- la ville (qui pourraient de-anonymiser l'institution). Correspondance fixe,
-- identique a la colonne calculee Power BI DIM_AGENCE[Agence (libelle)]
-- -> coherence garantie sur les 2 pages du dashboard.
SELECT
    COD_AGENCE,
    CASE COD_AGENCE
        WHEN 'D01' THEN 'Agence 01'
        WHEN 'G02' THEN 'Agence 02'
        WHEN 'D03' THEN 'Agence 03'
        WHEN 'D04' THEN 'Agence 04'
        WHEN 'D05' THEN 'Agence 05'
        WHEN 'Y01' THEN 'Agence 06'
        WHEN 'B01' THEN 'Agence 07'
        WHEN 'D06' THEN 'Agence 08'
        WHEN 'O02' THEN 'Agence 09'
        WHEN 'Y02' THEN 'Agence 10'
        WHEN 'DG1' THEN 'Siege (DG)'
        ELSE COD_AGENCE
    END AS NOM_AGENCE,
    CAST(NULL AS varchar(40)) AS VILLE   -- ville retiree (anonymisation)
FROM dbo.AGENCE;


/*-------------------------------------------------------------------------------
  C. DIM_GESTIONNAIRE  (OLE DB Source, connexion = CoreBanking_EMF)
     Mapping destination : COD_GEST, LIBELLE_GEST, COD_AGENCE, STATUT
     Identique au 1er mart : ANONYMISATION (ni NOM ni PRENOM, libelle neutre).
     IMPORTANT : meme ORDER BY que le 1er mart -> un COD_GEST donne recoit le
     meme libelle GEST-XXX dans les deux marts (coherence inter-dashboards).
-------------------------------------------------------------------------------*/
SELECT
    g.COD_GEST,
    'GEST-' + RIGHT('000' + CAST(ROW_NUMBER() OVER (ORDER BY g.COD_GEST) AS varchar(3)), 3) AS LIBELLE_GEST,
    CASE WHEN g.COD_AGENCE IN (SELECT a.COD_AGENCE FROM dbo.AGENCE a)
         THEN g.COD_AGENCE ELSE NULL END AS COD_AGENCE,
    CASE WHEN g.DATE_DEPART IS NULL THEN 'Actif' ELSE 'Parti' END AS STATUT
FROM dbo.GESTIONNAIRE g
UNION ALL
-- Membre "inconnu" (pattern Kimball) : cible des rares enregistrements sources
-- au COD_GEST vide ou orphelin (12 ADHERENT + 57 DEMPRET constates), pour ne
-- pas faire echouer les lookups SSIS ni perdre les lignes.
SELECT 'XXXXXX', 'GEST-INC', NULL, 'Inconnu';


/*-------------------------------------------------------------------------------
  D. DIM_PRODUIT  (OLE DB Source, connexion = CoreBanking_EMF)
     Mapping destination : FAMILLE, COD_PRODUIT, NOM_PRODUIT
     (PRODUIT_ID = IDENTITY cote destination, ne pas mapper)
     Dimension conforme ETENDUE : union des deux referentiels sources.
       - PRDT_CRD (81 produits de credit)
       - PRDT_EPG (16 produits d'epargne)
-------------------------------------------------------------------------------*/
SELECT
    'CREDIT'                       AS FAMILLE,
    CAST(COD_PRDT_CRD AS varchar(5)) AS COD_PRODUIT,
    CAST(NOM_PRDT_CRD AS varchar(60)) AS NOM_PRODUIT
FROM dbo.PRDT_CRD
UNION ALL
SELECT
    'EPARGNE',
    CAST(COD_PRDT_EPG AS varchar(5)),
    CAST(NOM_PRDT_EPG AS varchar(60))
FROM dbo.PRDT_EPG
UNION ALL
-- Pseudo-produit : canal collecte journaliere vu du guichet (comptes 38102
-- "operations commerciaux Epargne mobile" + comptes membres T_COMPTES).
-- Il n'existe pas dans PRDT_EPG, on le cree pour porter cette famille de flux.
SELECT 'EPARGNE', 'EPM', 'Epargne mobile (collecte journaliere)';
