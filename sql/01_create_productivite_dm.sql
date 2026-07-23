/*===============================================================================
  Projet      : Portfolio Power BI - Productivite & mobilisation des ressources (EMF)
  Script      : 01_create_productivite_dm.sql
  Objet       : Creation du data mart PRODUCTIVITE_DM (schema en etoile)
  Source      : CoreBanking_EMF (core banking) - alimentation via SSIS
  Fenetre     : janvier 2018 -> novembre 2024 (83 mois complets)
                Borne basse : migration vers le core banking fin 2017.
                Borne haute : dernier mois complet disponible (dec. 2024 tronque).
  Instance    : localhost\MS_SQL_SRS  (SQL Server 2019)
  Auteur      : Arnold
  Note        : Schema cree AVANT les packages SSIS (les destinations OLE DB
                doivent exister pour mapper les colonnes au design).
                Aucune donnee personnelle (PII) ne sera chargee ici :
                  - gestionnaires anonymises (LIBELLE_GEST = 'GEST-XXX')
                  - aucune dimension client (faits agreges au mois)
                Perimetre : activite guichet uniquement (le module de collecte
                journaliere - tables T_* - est hors perimetre ; ses fonds
                remontent dans les depots guichet et sont donc bien mesures).
                Grain des faits : mensuel (DATE_MOIS_ID = 1er jour du mois).
===============================================================================*/

/*--------------------------------------------------------------------------
  1. Base de donnees
--------------------------------------------------------------------------*/
IF DB_ID('PRODUCTIVITE_DM') IS NULL
BEGIN
    CREATE DATABASE PRODUCTIVITE_DM;
END
GO

USE PRODUCTIVITE_DM;
GO

/*--------------------------------------------------------------------------
  2. Nettoyage (idempotent) - faits d'abord, dimensions ensuite (FK)
--------------------------------------------------------------------------*/
IF OBJECT_ID('dbo.FACT_REVENU','U')            IS NOT NULL DROP TABLE dbo.FACT_REVENU;
IF OBJECT_ID('dbo.FACT_PRODUCTION_CREDIT','U') IS NOT NULL DROP TABLE dbo.FACT_PRODUCTION_CREDIT;
IF OBJECT_ID('dbo.FACT_EPARGNE','U')           IS NOT NULL DROP TABLE dbo.FACT_EPARGNE;
IF OBJECT_ID('dbo.FACT_ADHESION','U')          IS NOT NULL DROP TABLE dbo.FACT_ADHESION;
IF OBJECT_ID('dbo.DIM_TYPE_REVENU','U')        IS NOT NULL DROP TABLE dbo.DIM_TYPE_REVENU;
IF OBJECT_ID('dbo.DIM_PRODUIT','U')            IS NOT NULL DROP TABLE dbo.DIM_PRODUIT;
IF OBJECT_ID('dbo.DIM_GESTIONNAIRE','U')       IS NOT NULL DROP TABLE dbo.DIM_GESTIONNAIRE;
IF OBJECT_ID('dbo.DIM_AGENCE','U')             IS NOT NULL DROP TABLE dbo.DIM_AGENCE;
IF OBJECT_ID('dbo.DIM_CALENDRIER','U')         IS NOT NULL DROP TABLE dbo.DIM_CALENDRIER;
GO

/*--------------------------------------------------------------------------
  3. Dimensions
--------------------------------------------------------------------------*/

-- 3.1 Calendrier (une ligne par jour, 2018-01-01 -> 2024-11-30 ;
--     meme structure que PORTFOLIO_CREDIT_DM ; les faits mensuels pointent
--     sur le DATE_ID du 1er jour du mois, la table jour permet la time
--     intelligence DAX native cote Power BI)
CREATE TABLE dbo.DIM_CALENDRIER (
    DATE_ID      INT          NOT NULL,   -- ex : 20240930
    DATE_JOUR    DATE         NOT NULL,
    ANNEE        SMALLINT     NOT NULL,
    TRIMESTRE    TINYINT      NOT NULL,
    MOIS         TINYINT      NOT NULL,
    NOM_MOIS     VARCHAR(15)  NOT NULL,
    ANNEE_MOIS   CHAR(7)      NOT NULL,   -- ex : 2024-09
    JOUR         TINYINT      NOT NULL,
    CONSTRAINT PK_DIM_CALENDRIER PRIMARY KEY (DATE_ID)
);
GO

-- 3.2 Agence (dimension conforme, identique au 1er mart)
CREATE TABLE dbo.DIM_AGENCE (
    COD_AGENCE   CHAR(3)      NOT NULL,
    NOM_AGENCE   VARCHAR(100) NULL,
    VILLE        VARCHAR(40)  NULL,
    CONSTRAINT PK_DIM_AGENCE PRIMARY KEY (COD_AGENCE)
);
GO

-- 3.3 Gestionnaire (dimension conforme, anonymisee : libelle neutre GEST-XXX)
CREATE TABLE dbo.DIM_GESTIONNAIRE (
    GEST_ID      INT          IDENTITY(1,1) NOT NULL,
    COD_GEST     CHAR(6)      NOT NULL,   -- cle metier (code interne, non nominatif)
    LIBELLE_GEST VARCHAR(20)  NOT NULL,   -- ex : GEST-001
    COD_AGENCE   CHAR(3)      NULL,
    STATUT       VARCHAR(10)  NULL,       -- Actif / Parti
    CONSTRAINT PK_DIM_GESTIONNAIRE PRIMARY KEY (GEST_ID),
    CONSTRAINT UQ_DIM_GESTIONNAIRE_COD UNIQUE (COD_GEST),
    CONSTRAINT FK_GEST_AGENCE FOREIGN KEY (COD_AGENCE)
        REFERENCES dbo.DIM_AGENCE (COD_AGENCE)
);
GO

-- 3.4 Produit (dimension conforme ETENDUE : produits de credit ET d'epargne.
--     Cle de substitution car les referentiels credit et epargne sont
--     distincts dans la source et leurs codes peuvent entrer en collision.)
CREATE TABLE dbo.DIM_PRODUIT (
    PRODUIT_ID   INT          IDENTITY(1,1) NOT NULL,
    FAMILLE      VARCHAR(10)  NOT NULL,   -- 'CREDIT' / 'EPARGNE'
    COD_PRODUIT  VARCHAR(5)   NOT NULL,   -- cle metier dans son referentiel source
    NOM_PRODUIT  VARCHAR(60)  NULL,
    CONSTRAINT PK_DIM_PRODUIT PRIMARY KEY (PRODUIT_ID),
    CONSTRAINT UQ_DIM_PRODUIT UNIQUE (FAMILLE, COD_PRODUIT)
);
GO

-- 3.5 Type de revenu (table de reference figee, alimentee ici ;
--     hierarchie Categorie -> Type pour l'analyse de structure des revenus.
--     La TVA collectee (types 10/11 de TYPE_FRAIS_CRD) est EXCLUE : collectee
--     pour le compte de l'Etat, ce n'est pas un revenu de l'institution.)
CREATE TABLE dbo.DIM_TYPE_REVENU (
    TYPE_REVENU_ID TINYINT      NOT NULL,
    CATEGORIE      VARCHAR(30)  NOT NULL,
    LIBELLE        VARCHAR(50)  NOT NULL,
    ORDRE          TINYINT      NOT NULL,
    CONSTRAINT PK_DIM_TYPE_REVENU PRIMARY KEY (TYPE_REVENU_ID)
);
GO

INSERT INTO dbo.DIM_TYPE_REVENU (TYPE_REVENU_ID, CATEGORIE, LIBELLE, ORDRE)
VALUES
    ( 1, 'Revenus credit',    'Interets encaisses',                 1),  -- REMBOURS.INTERET_REMB
    ( 2, 'Revenus credit',    'Penalites encaissees',               2),  -- REMBOURS.PENALITE_REMB
    ( 3, 'Revenus credit',    'Commissions sur remboursement',      3),  -- REMBOURS.COMMISSION_REMB
    ( 4, 'Revenus credit',    'Frais de dossier',                   4),  -- COMMISSION_CRD (types dossier)
    ( 5, 'Revenus credit',    'Frais de gestion',                   5),  -- COMMISSION_CRD (types gestion)
    ( 6, 'Revenus credit',    'Autres commissions credit',          6),  -- COMMISSION_CRD (autres, hors TVA)
    ( 7, 'Revenus services',  'Frais de tenue de compte',           7),  -- FRAIS_TENUE_COMPTE
    ( 8, 'Revenus services',  'Autres revenus guichet',             8),  -- OPERATION (codes revenus)
    ( 9, 'Revenus adhesion',  'Frais d''adhesion et d''ouverture de compte', 9),  -- HDPM comptes 755100 + 719220 (bascule loi de finances 2022)
    (10, 'Revenus adhesion',  'Assurance-vie minimum',             10),  -- RUBINS x RUBINS_RUBADH (rub. 03)
    (11, 'Revenus adhesion',  'Fonds de solidarite',               11); -- RUBINS x RUBINS_RUBADH (rub. 02, residuel apres 2018)
GO

/*--------------------------------------------------------------------------
  4. Tables de faits (grain mensuel : DATE_MOIS_ID = DATE_ID du 1er du mois)
--------------------------------------------------------------------------*/

-- 4.1 FACT_ADHESION : grain = mois x agence x gestionnaire
--     Source : ADHERENT (DATE_INSCRIP) - source exhaustive des adhesions.
--     Le montant des adhesions est porte par FACT_REVENU (cat. 'Revenus
--     adhesion') : une seule source de verite, pas de double compte.
CREATE TABLE dbo.FACT_ADHESION (
    DATE_MOIS_ID   INT          NOT NULL,
    COD_AGENCE     CHAR(3)      NOT NULL,
    GEST_ID        INT          NOT NULL,
    NB_ADHESIONS   INT          NOT NULL,
    CONSTRAINT PK_FACT_ADHESION PRIMARY KEY (DATE_MOIS_ID, COD_AGENCE, GEST_ID),
    CONSTRAINT FK_FA_CAL    FOREIGN KEY (DATE_MOIS_ID) REFERENCES dbo.DIM_CALENDRIER (DATE_ID),
    CONSTRAINT FK_FA_AGENCE FOREIGN KEY (COD_AGENCE)   REFERENCES dbo.DIM_AGENCE (COD_AGENCE),
    CONSTRAINT FK_FA_GEST   FOREIGN KEY (GEST_ID)      REFERENCES dbo.DIM_GESTIONNAIRE (GEST_ID)
);
GO

-- 4.2 FACT_EPARGNE : grain = mois x agence x produit d'epargne
--     Source : OPERATION (DEPO + DPCH = depots ; RETR = retraits).
--     Rattachement a l'agence DU COMPTE (COMPTES.COD_AGENCE), pas a la
--     caisse encaissante : on mesure la capacite d'une agence a mobiliser
--     SA clientele. Produit via COMPTES_EPG.COD_PRDT_EPG.
--     La collecte nette (depots - retraits) est une mesure DAX, pas une colonne.
CREATE TABLE dbo.FACT_EPARGNE (
    DATE_MOIS_ID     INT          NOT NULL,
    COD_AGENCE       CHAR(3)      NOT NULL,
    PRODUIT_ID       INT          NOT NULL,
    NB_DEPOTS        INT          NOT NULL DEFAULT 0,
    MONTANT_DEPOTS   MONEY        NOT NULL DEFAULT 0,
    NB_RETRAITS      INT          NOT NULL DEFAULT 0,
    MONTANT_RETRAITS MONEY        NOT NULL DEFAULT 0,
    CONSTRAINT PK_FACT_EPARGNE PRIMARY KEY (DATE_MOIS_ID, COD_AGENCE, PRODUIT_ID),
    CONSTRAINT FK_FEP_CAL    FOREIGN KEY (DATE_MOIS_ID) REFERENCES dbo.DIM_CALENDRIER (DATE_ID),
    CONSTRAINT FK_FEP_AGENCE FOREIGN KEY (COD_AGENCE)   REFERENCES dbo.DIM_AGENCE (COD_AGENCE),
    CONSTRAINT FK_FEP_PRDT   FOREIGN KEY (PRODUIT_ID)   REFERENCES dbo.DIM_PRODUIT (PRODUIT_ID)
);
GO

-- 4.3 FACT_PRODUCTION_CREDIT : grain = mois x agence x gestionnaire x produit
--     Source : dossiers de pret (production = acte commercial : nb et montant
--     des prets mis en place dans le mois ; AUCUNE notion de qualite/PAR,
--     etancheite volontaire avec PORTFOLIO_CREDIT_DM).
CREATE TABLE dbo.FACT_PRODUCTION_CREDIT (
    DATE_MOIS_ID        INT          NOT NULL,
    COD_AGENCE          CHAR(3)      NOT NULL,
    GEST_ID             INT          NOT NULL,
    PRODUIT_ID          INT          NOT NULL,
    NB_PRETS_DECAISSES  INT          NOT NULL,
    MONTANT_DECAISSE    MONEY        NOT NULL,
    CONSTRAINT PK_FACT_PRODUCTION_CREDIT PRIMARY KEY (DATE_MOIS_ID, COD_AGENCE, GEST_ID, PRODUIT_ID),
    CONSTRAINT FK_FPC_CAL    FOREIGN KEY (DATE_MOIS_ID) REFERENCES dbo.DIM_CALENDRIER (DATE_ID),
    CONSTRAINT FK_FPC_AGENCE FOREIGN KEY (COD_AGENCE)   REFERENCES dbo.DIM_AGENCE (COD_AGENCE),
    CONSTRAINT FK_FPC_GEST   FOREIGN KEY (GEST_ID)      REFERENCES dbo.DIM_GESTIONNAIRE (GEST_ID),
    CONSTRAINT FK_FPC_PRDT   FOREIGN KEY (PRODUIT_ID)   REFERENCES dbo.DIM_PRODUIT (PRODUIT_ID)
);
GO

-- 4.4 FACT_REVENU : grain = mois x agence x type de revenu
--     Sources unifiees (5) : REMBOURS (interets/penalites/commissions
--     encaissees, par DATE_REMB), COMMISSION_CRD, FRAIS_TENUE_COMPTE,
--     OPERATION (codes revenus guichet), RUBINS x RUBINS_RUBADH (adhesion).
--     Optique ENCAISSEMENT (cash) et non produits courus : choix documente.
CREATE TABLE dbo.FACT_REVENU (
    DATE_MOIS_ID   INT          NOT NULL,
    COD_AGENCE     CHAR(3)      NOT NULL,
    TYPE_REVENU_ID TINYINT      NOT NULL,
    NB_OPERATIONS  INT          NOT NULL,
    MONTANT_REVENU MONEY        NOT NULL,
    CONSTRAINT PK_FACT_REVENU PRIMARY KEY (DATE_MOIS_ID, COD_AGENCE, TYPE_REVENU_ID),
    CONSTRAINT FK_FR_CAL    FOREIGN KEY (DATE_MOIS_ID)   REFERENCES dbo.DIM_CALENDRIER (DATE_ID),
    CONSTRAINT FK_FR_AGENCE FOREIGN KEY (COD_AGENCE)     REFERENCES dbo.DIM_AGENCE (COD_AGENCE),
    CONSTRAINT FK_FR_TYPE   FOREIGN KEY (TYPE_REVENU_ID) REFERENCES dbo.DIM_TYPE_REVENU (TYPE_REVENU_ID)
);
GO

PRINT 'Data mart PRODUCTIVITE_DM cree : 5 dimensions + 4 faits.';
GO
