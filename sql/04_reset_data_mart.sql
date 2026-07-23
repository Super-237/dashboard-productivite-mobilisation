/*===============================================================================
  Projet : Portfolio Power BI - Productivite & mobilisation des ressources (EMF)
  Script : 04_reset_data_mart.sql
  Objet  : Vidage (reset) des tables pour rendre les chargements idempotents.
  Regle  : on vide les FAITS avant les DIMENSIONS (cles etrangeres).
           DIM_TYPE_REVENU n'est PAS videe : elle est alimentee par le DDL (01),
           pas par les packages SSIS (meme logique que DIM_CLASSE_RETARD au
           1er projet).
  Usage  : - Bloc A -> Execute SQL Task EN TETE du Package 1 (dimensions),
                        connexion PRODUCTIVITE_DM. Vide tout le data mart.
           - Bloc B -> Execute SQL Task EN TETE du Package 2 (faits),
                        connexion PRODUCTIVITE_DM. Vide seulement les faits.
===============================================================================*/


/*-------------------------------------------------------------------------------
  A. RESET COMPLET  (en tete du Package 1 - dimensions)
-------------------------------------------------------------------------------*/
USE PRODUCTIVITE_DM;

-- 1) Les faits d'abord (non references -> TRUNCATE possible)
TRUNCATE TABLE dbo.FACT_REVENU;
TRUNCATE TABLE dbo.FACT_PRODUCTION_CREDIT;
TRUNCATE TABLE dbo.FACT_EPARGNE;
TRUNCATE TABLE dbo.FACT_ADHESION;

-- 2) Les dimensions ensuite (referencees par FK -> DELETE, ordre des dependances)
--    DIM_TYPE_REVENU exclue : referentiel fige charge par le script 01.
DELETE FROM dbo.DIM_GESTIONNAIRE;   -- enfant de DIM_AGENCE
DELETE FROM dbo.DIM_PRODUIT;
DELETE FROM dbo.DIM_AGENCE;
DELETE FROM dbo.DIM_CALENDRIER;

-- 3) Reseed des identites (DELETE ne remet pas le compteur a 0)
DBCC CHECKIDENT ('dbo.DIM_GESTIONNAIRE', RESEED, 0);
DBCC CHECKIDENT ('dbo.DIM_PRODUIT',      RESEED, 0);


/*-------------------------------------------------------------------------------
  B. RESET DES FAITS UNIQUEMENT  (en tete du Package 2 - faits)
     Permet de rejouer le package des faits sans toucher aux dimensions.
-------------------------------------------------------------------------------*/
USE PRODUCTIVITE_DM;

TRUNCATE TABLE dbo.FACT_REVENU;
TRUNCATE TABLE dbo.FACT_PRODUCTION_CREDIT;
TRUNCATE TABLE dbo.FACT_EPARGNE;
TRUNCATE TABLE dbo.FACT_ADHESION;
