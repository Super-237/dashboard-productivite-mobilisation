/*===============================================================================
  Projet : Portfolio Power BI - Productivite & mobilisation des ressources (EMF)
  Script : 03_sources_faits.sql
  Objet  : Requetes SOURCE pour le chargement des tables de faits via SSIS.
  Fenetre: 2018-01-01 -> 2024-11-30 (dec. 2024 exclu : donnees tronquees au 09/12).
  Usage  : Blocs E a H a coller dans les OLE DB Source (connexion SOURCE
           CoreBanking_EMF). Cles de substitution (GEST_ID, PRODUIT_ID) resolues
           par des Lookups SSIS, pas dans le SQL.

  Regles metier et choix documentes :
   - Grain mensuel : DATE_MOIS_ID = DATE_ID du 1er jour du mois (AAAAMM01).
   - Adhesions : source ADHERENT (exhaustive). FIN_AFFILIATION/COD_MOTIF_DEPART
     non fiables -> adhesions BRUTES uniquement, pas de "collecte nette de membres".
   - Epargne : rattachement a l'agence DU COMPTE (COMPTES.COD_AGENCE), pas a la
     caisse encaissante -> on mesure la mobilisation de la clientele de l'agence.
     Produits techniques exclus de la mobilisation : 006 (depot de garantie),
     009 (comptes salaires personnel), 012/013 (comptes de recouvrement).
   - Production credit = acte commercial (prets mis en place dans le mois).
     Tous etats confondus (DC/SD/PE) : un pret decaisse est de la production,
     quel que soit son destin ulterieur (la qualite releve de l'autre dashboard).
   - Revenus en optique ENCAISSEMENT (cash). TVA exclue partout (collectee pour
     l'Etat, pas une production). Frais d'adhesion sources depuis HDPM (comptes
     755100 + 719220) : couvre les 3 canaux de saisie (module 0013, AOPP, ECRI),
     la bascule de compte de la loi de finances 2022, et exclut la TVA de fait.
   - HDPM sert aussi de source de RECONCILIATION globale (script 05 a venir).
===============================================================================*/


/*-------------------------------------------------------------------------------
  E. FACT_ADHESION  (OLE DB Source, connexion = CoreBanking_EMF)
     Grain : mois x agence x gestionnaire.
     Sortie : DATE_MOIS_ID, COD_AGENCE, COD_GEST, NB_ADHESIONS
     -> Lookup SSIS : COD_GEST -> GEST_ID
     Note : les COD_GEST vides ou orphelins (12 lignes constatees) sont
     reroutes vers le membre inconnu 'XXXXXX' de DIM_GESTIONNAIRE.
-------------------------------------------------------------------------------*/
SELECT
    CONVERT(int, CONVERT(char(6), a.DATE_INSCRIP, 112) + '01') AS DATE_MOIS_ID,
    a.COD_AGENCE,
    CASE WHEN g.COD_GEST IS NULL THEN 'XXXXXX' ELSE a.COD_GEST END AS COD_GEST,
    COUNT(*) AS NB_ADHESIONS
FROM dbo.ADHERENT a
LEFT JOIN dbo.GESTIONNAIRE g ON g.COD_GEST = a.COD_GEST
WHERE a.DATE_INSCRIP >= '2018-01-01'
  AND a.DATE_INSCRIP <  '2024-12-01'
GROUP BY
    CONVERT(char(6), a.DATE_INSCRIP, 112),
    a.COD_AGENCE,
    CASE WHEN g.COD_GEST IS NULL THEN 'XXXXXX' ELSE a.COD_GEST END;


/*-------------------------------------------------------------------------------
  F. FACT_EPARGNE  (OLE DB Source, connexion = CoreBanking_EMF)
     Grain : mois x agence (du compte) x produit d'epargne.
     Sortie : DATE_MOIS_ID, COD_AGENCE, COD_PRDT_EPG, NB_DEPOTS, MONTANT_DEPOTS,
              NB_RETRAITS, MONTANT_RETRAITS
     -> Lookup SSIS : (FAMILLE='EPARGNE', COD_PRODUIT) -> PRODUIT_ID
     Notes :
       - DEPO + DPCH = depots (especes + cheques) ; RETR = retraits.
       - Deux familles de flux :
           1) Epargne classique : comptes du referentiel COMPTES_EPG
              (produits techniques 006/009/012/013 exclus de la mobilisation).
           2) Pseudo-produit 'EPM' = canal collecte journaliere vu du guichet :
              entrees = versements des commerciaux sur les comptes 38102
              ("operations commerciaux Epargne mobile") apres collecte terrain ;
              sorties = retraits des membres sur leurs comptes collecte
              (T_COMPTES, lue ici uniquement comme table de classification).
              Le detail interne du module collecte (cycles, collecteurs,
              T_OPERATION) reste hors perimetre.
       - La collecte nette (depots - retraits) est une mesure DAX, pas une colonne.
-------------------------------------------------------------------------------*/
SELECT
    DATE_MOIS_ID, COD_AGENCE, COD_PRODUIT,
    SUM(NB_DEP)  AS NB_DEPOTS,
    SUM(MT_DEP)  AS MONTANT_DEPOTS,
    SUM(NB_RET)  AS NB_RETRAITS,
    SUM(MT_RET)  AS MONTANT_RETRAITS
FROM (
    /* 1) Epargne classique (referentiel COMPTES_EPG) */
    SELECT
        CONVERT(int, CONVERT(char(6), o.DATE_OPERATION, 112) + '01') AS DATE_MOIS_ID,
        c.COD_AGENCE,
        ce.COD_PRDT_EPG AS COD_PRODUIT,
        CASE WHEN o.COD_TYP_OPERAT IN ('DEPO','DPCH') THEN 1 ELSE 0 END         AS NB_DEP,
        CASE WHEN o.COD_TYP_OPERAT IN ('DEPO','DPCH') THEN o.MONTANT ELSE 0 END AS MT_DEP,
        CASE WHEN o.COD_TYP_OPERAT = 'RETR' THEN 1 ELSE 0 END                   AS NB_RET,
        CASE WHEN o.COD_TYP_OPERAT = 'RETR' THEN o.MONTANT ELSE 0 END           AS MT_RET
    FROM dbo.OPERATION o
    JOIN dbo.COMPTES     c  ON c.NUM_CPTE  = o.NUM_CPTE
    JOIN dbo.COMPTES_EPG ce ON ce.NUM_CPTE = o.NUM_CPTE
    WHERE o.COD_TYP_OPERAT IN ('DEPO','DPCH','RETR')
      AND o.DATE_OPERATION >= '2018-01-01'
      AND o.DATE_OPERATION <  '2024-12-01'
      AND ce.COD_PRDT_EPG NOT IN ('006','009','012','013')   -- techniques : hors mobilisation

    UNION ALL

    /* 2a) Collecte journaliere - entrees : versements des commerciaux (38102) */
    SELECT
        CONVERT(int, CONVERT(char(6), o.DATE_OPERATION, 112) + '01'),
        c.COD_AGENCE,
        'EPM',
        CASE WHEN o.COD_TYP_OPERAT IN ('DEPO','DPCH') THEN 1 ELSE 0 END,
        CASE WHEN o.COD_TYP_OPERAT IN ('DEPO','DPCH') THEN o.MONTANT ELSE 0 END,
        CASE WHEN o.COD_TYP_OPERAT = 'RETR' THEN 1 ELSE 0 END,
        CASE WHEN o.COD_TYP_OPERAT = 'RETR' THEN o.MONTANT ELSE 0 END
    FROM dbo.OPERATION o
    JOIN dbo.COMPTES c ON c.NUM_CPTE = o.NUM_CPTE
    WHERE o.COD_TYP_OPERAT IN ('DEPO','DPCH','RETR')
      AND o.DATE_OPERATION >= '2018-01-01'
      AND o.DATE_OPERATION <  '2024-12-01'
      AND c.CPTE_GAL = '38102'

    UNION ALL

    /* 2b) Collecte journaliere - flux guichet sur comptes membres (T_COMPTES) */
    SELECT
        CONVERT(int, CONVERT(char(6), o.DATE_OPERATION, 112) + '01'),
        tc.CODE_AGENCE,
        'EPM',
        CASE WHEN o.COD_TYP_OPERAT IN ('DEPO','DPCH') THEN 1 ELSE 0 END,
        CASE WHEN o.COD_TYP_OPERAT IN ('DEPO','DPCH') THEN o.MONTANT ELSE 0 END,
        CASE WHEN o.COD_TYP_OPERAT = 'RETR' THEN 1 ELSE 0 END,
        CASE WHEN o.COD_TYP_OPERAT = 'RETR' THEN o.MONTANT ELSE 0 END
    FROM dbo.OPERATION o
    JOIN dbo.T_COMPTES tc ON tc.NUM_CMPTE = o.NUM_CPTE
    WHERE o.COD_TYP_OPERAT IN ('DEPO','DPCH','RETR')
      AND o.DATE_OPERATION >= '2018-01-01'
      AND o.DATE_OPERATION <  '2024-12-01'
) f
GROUP BY DATE_MOIS_ID, COD_AGENCE, COD_PRODUIT;


/*-------------------------------------------------------------------------------
  G. FACT_PRODUCTION_CREDIT  (OLE DB Source, connexion = CoreBanking_EMF)
     Grain : mois x agence x gestionnaire x produit de credit.
     Sortie : DATE_MOIS_ID, COD_AGENCE, COD_GEST, COD_PRDT_CRD,
              NB_PRETS_DECAISSES, MONTANT_DECAISSE
     -> Lookups SSIS : COD_GEST -> GEST_ID ; (FAMILLE='CREDIT', COD_PRDT_CRD)
        -> PRODUIT_ID
     Notes :
       - Production = date de mise en place (DATE_EFFET), etats DC/SD/PE
         confondus (un pret radie plus tard reste de la production du mois).
       - Agence = LEFT(NUM_DOSSIER, 3) (convention du 1er mart, validee).
       - Gestionnaire/produit via DEMPRET (deduplique, meme pattern que le 1er mart).
-------------------------------------------------------------------------------*/
WITH ddem AS (
    SELECT REF_DEMANDE, COD_GEST, COD_PRDT_CRD,
           ROW_NUMBER() OVER (PARTITION BY REF_DEMANDE ORDER BY DATE_VALIDATION DESC) AS rn
    FROM dbo.DEMPRET
)
SELECT
    CONVERT(int, CONVERT(char(6), p.DATE_EFFET, 112) + '01') AS DATE_MOIS_ID,
    LEFT(p.NUM_DOSSIER, 3) AS COD_AGENCE,
    CASE WHEN g.COD_GEST IS NULL THEN 'XXXXXX' ELSE d.COD_GEST END AS COD_GEST,
    d.COD_PRDT_CRD,
    COUNT(*)              AS NB_PRETS_DECAISSES,
    SUM(p.MONTANT_PRET)   AS MONTANT_DECAISSE
FROM dbo.PRETS p
LEFT JOIN ddem d ON d.REF_DEMANDE = p.REF_DEMANDE AND d.rn = 1
LEFT JOIN dbo.GESTIONNAIRE g ON g.COD_GEST = d.COD_GEST
WHERE p.ETAT_PRET IN ('DC','SD','PE')
  AND p.DATE_EFFET >= '2018-01-01'
  AND p.DATE_EFFET <  '2024-12-01'
GROUP BY
    CONVERT(char(6), p.DATE_EFFET, 112),
    LEFT(p.NUM_DOSSIER, 3),
    CASE WHEN g.COD_GEST IS NULL THEN 'XXXXXX' ELSE d.COD_GEST END,
    d.COD_PRDT_CRD;


/*-------------------------------------------------------------------------------
  H. FACT_REVENU  (OLE DB Source, connexion = CoreBanking_EMF)
     Grain : mois x agence x type de revenu (cf. DIM_TYPE_REVENU).
     Sortie : DATE_MOIS_ID, COD_AGENCE, TYPE_REVENU_ID, NB_OPERATIONS, MONTANT_REVENU
     Union de 5 blocs sources, re-agregee en sortie.

     MAPPING DES TYPES (a valider ligne a ligne) :
       1  Interets encaisses            <- REMBOURS.INTERET_REMB    (mois de DATE_REMB)
       2  Penalites encaissees          <- REMBOURS.PENALITE_REMB
       3  Commissions sur remboursement <- REMBOURS.COMMISSION_REMB
       4  Frais de dossier              <- COMMISSION_CRD, types 01,02,03,12,14,17,20,21
       5  Frais de gestion              <- COMMISSION_CRD, types 04,05,06,13,15,16,18,19
       6  Autres commissions credit     <- COMMISSION_CRD types 07,08,09
                                           + OPERATION codes 0093,0094,0150 (convention/
                                           assurance pret), 0106,0107,0149 (penalites guichet)
       7  Frais de tenue de compte      <- FRAIS_TENUE_COMPTE
       8  Autres revenus guichet        <- OPERATION codes documentes ci-dessous
       9  Frais adhesion + ouverture    <- HDPM comptes 755100 + 719220 (credits nets)
       10 Assurance-vie minimum         <- RUBINS x RUBINS_RUBADH rubrique 03
       11 Fonds de solidarite           <- RUBINS x RUBINS_RUBADH rubrique 02
     EXCLUSIONS assumees :
       - COMMISSION_CRD types 10/11 (TVA) et lignes sans type.
       - OPERATION AOPP/AOCP generiques : texte libre non classable de facon fiable
         (le canal manuel des frais d'adhesion est deja capte par le bloc HDPM ;
         le reste est couvert par la reconciliation comptable globale, script 05).
-------------------------------------------------------------------------------*/
SELECT
    DATE_MOIS_ID, COD_AGENCE, TYPE_REVENU_ID,
    SUM(NB)      AS NB_OPERATIONS,
    SUM(MONTANT) AS MONTANT_REVENU
FROM (
    /* --- Types 1/2/3 : encaissements sur credits (REMBOURS) ------------------
       Agence = LEFT(NUM_DOSSIER,3), coherent avec la production credit.      */
    SELECT
        CONVERT(int, CONVERT(char(6), r.DATE_REMB, 112) + '01') AS DATE_MOIS_ID,
        LEFT(r.NUM_DOSSIER, 3) AS COD_AGENCE,
        t.TYPE_REVENU_ID,
        t.NB,
        t.MONTANT
    FROM dbo.REMBOURS r
    CROSS APPLY (VALUES
        (CAST(1 AS tinyint), CASE WHEN r.INTERET_REMB    > 0 THEN 1 ELSE 0 END, r.INTERET_REMB),
        (CAST(2 AS tinyint), CASE WHEN r.PENALITE_REMB   > 0 THEN 1 ELSE 0 END, r.PENALITE_REMB),
        (CAST(3 AS tinyint), CASE WHEN r.COMMISSION_REMB > 0 THEN 1 ELSE 0 END, r.COMMISSION_REMB)
    ) t (TYPE_REVENU_ID, NB, MONTANT)
    WHERE r.DATE_REMB >= '2018-01-01' AND r.DATE_REMB < '2024-12-01'
      AND t.MONTANT <> 0

    UNION ALL

    /* --- Types 4/5/6 : commissions et frais sur credit (COMMISSION_CRD) ------
       Agence via le compte du membre (COMPTES), TVA (10/11) exclue.          */
    SELECT
        CONVERT(int, CONVERT(char(6), cc.DATE_OPERATION, 112) + '01'),
        c.COD_AGENCE,
        CASE WHEN cc.COD_TYPE_FRAIS IN ('01','02','03','12','14','17','20','21') THEN 4
             WHEN cc.COD_TYPE_FRAIS IN ('04','05','06','13','15','16','18','19') THEN 5
             ELSE 6 END,
        1,
        cc.MONTANT
    FROM dbo.COMMISSION_CRD cc
    JOIN dbo.COMPTES c ON c.NUM_CPTE = cc.NUM_CPTE
    WHERE cc.DATE_OPERATION >= '2018-01-01' AND cc.DATE_OPERATION < '2024-12-01'
      AND cc.COD_TYPE_FRAIS IN ('01','02','03','04','05','06','07','08','09',
                                '12','13','14','15','16','17','18','19','20','21')

    UNION ALL

    /* --- Type 6 (complement) : frais lies au credit encaisses au guichet ----- */
    SELECT
        CONVERT(int, CONVERT(char(6), o.DATE_OPERATION, 112) + '01'),
        c.COD_AGENCE,
        6,
        1,
        o.MONTANT
    FROM dbo.OPERATION o
    JOIN dbo.COMPTES c ON c.NUM_CPTE = o.NUM_CPTE
    WHERE o.DATE_OPERATION >= '2018-01-01' AND o.DATE_OPERATION < '2024-12-01'
      AND o.COD_TYP_OPERAT IN ('0093','0094','0150',      -- convention / assurance pret
                               '0106','0107','0149')      -- penalites encaissees au guichet

    UNION ALL

    /* --- Type 7 : frais de tenue de compte ----------------------------------- */
    SELECT
        CONVERT(int, CONVERT(char(6), f.DATE_OPERATION, 112) + '01'),
        c.COD_AGENCE,
        7,
        1,
        f.MONTANT
    FROM dbo.FRAIS_TENUE_COMPTE f
    JOIN dbo.COMPTES c ON c.NUM_CPTE = f.NUM_CPTE
    WHERE f.DATE_OPERATION >= '2018-01-01' AND f.DATE_OPERATION < '2024-12-01'

    UNION ALL

    /* --- Type 8 : autres revenus guichet (liste FERMEE de codes) -------------
       0027 vente carnets collecte ; CMEC commission encaissement cheque ;
       CCHQ confection cheque interne ; 0116/0117/0121/0123/0124/0125/0128/
       0136 attestations & extraits ; 0127 livret epargne ; 0134 cheque de
       guichet ; 0135 chequiers ; 0007 renouvellement carnet membre.          */
    SELECT
        CONVERT(int, CONVERT(char(6), o.DATE_OPERATION, 112) + '01'),
        c.COD_AGENCE,
        8,
        1,
        o.MONTANT
    FROM dbo.OPERATION o
    JOIN dbo.COMPTES c ON c.NUM_CPTE = o.NUM_CPTE
    WHERE o.DATE_OPERATION >= '2018-01-01' AND o.DATE_OPERATION < '2024-12-01'
      AND o.COD_TYP_OPERAT IN ('0027','CMEC','CCHQ','0116','0117','0121','0123',
                               '0124','0125','0127','0128','0134','0135','0136','0007')

    UNION ALL

    /* --- Type 9 : frais d'adhesion et d'ouverture de compte (HDPM) -----------
       Credits nets sur 755100 (regime <= 2022) + 719220 (regime >= 2022).
       Capte les 3 canaux (module 0013, AOPP, ECRI), exclut la TVA (430320)
       par construction. Agence lue dans le numero de compte comptable.
       REPR/INVT/RSLT exclus (ecritures de cloture, pas des revenus).         */
    SELECT
        CONVERT(int, CONVERT(char(6), h.DATE_OPERATION, 112) + '01'),
        SUBSTRING(h.NUM_CPTE, 7, 3),
        9,
        CASE WHEN h.SENS_OPERATION = 'C' THEN 1 ELSE 0 END,
        CASE WHEN h.SENS_OPERATION = 'C' THEN h.MONTANT_TRANS ELSE -h.MONTANT_TRANS END
    FROM dbo.HDPM h
    WHERE h.DATE_OPERATION >= '2018-01-01' AND h.DATE_OPERATION < '2024-12-01'
      AND LEFT(h.NUM_CPTE, 6) IN ('755100','719220')
      AND h.COD_TYP_OPERAT NOT IN ('REPR','INVT','RSLT')

    UNION ALL

    /* --- Types 10/11 : assurance-vie minimum et fonds de solidarite ----------
       Source RUBINS (module d'inscription). Montants potentiellement TTC
       depuis 2021 : ecart chiffre par la reconciliation HDPM (script 05).
       Agence : 3 derniers caracteres de KP_CAIS_AGENCE (format '002D06') ;
       repli sur l'agence du membre (ADHERENT) quand le champ est vide.
       (Ne PAS joindre COMPTES : 91 % des inscriptions n'ont pas encore de
       compte au moment de la saisie, la jointure viderait la mesure.)        */
    SELECT
        CONVERT(int, CONVERT(char(6), r.DATE_RUBINS, 112) + '01'),
        COALESCE(NULLIF(RIGHT(LTRIM(RTRIM(r.KP_CAIS_AGENCE)), 3), ''), a.COD_AGENCE),
        CASE d.COD_RUBADH WHEN '03' THEN 10 ELSE 11 END,
        1,
        d.MONTANT_PAYE
    FROM dbo.RUBINS r
    JOIN dbo.RUBINS_RUBADH d ON d.NUM_TRANS = r.NUM_TRANS
    LEFT JOIN dbo.ADHERENT a ON a.COD_ADH   = r.COD_ADH
    WHERE r.DATE_RUBINS >= '2018-01-01' AND r.DATE_RUBINS < '2024-12-01'
      AND d.COD_RUBADH IN ('02','03')
) s
GROUP BY DATE_MOIS_ID, COD_AGENCE, TYPE_REVENU_ID;
