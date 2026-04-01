/******************************************************************************
Author: Teo Espero (IT Administrator)
Date: 04/01/2026

Query Title:
Meter-Based Service Connection Summary

Purpose:
This query builds a service connection summary using accounts that were
actually billed in a selected reading year and reading period. It is
intended to return one reporting row per lot, showing the service address,
the first known connection date for the lot, the latest active account, and
the latest valid active meter information.

Final Output Fields:
- Lot no
- Service Address
- City
- State
- Zip Code
- First Connection Date
- Latest Active Account
- Latest Account Start Date
- Latest Account End Date
- Meter Install Date
- Meter Serial Number
- Meter Manufacturer
- Meter Model
- Meter Size
- Meter Type

Business Rules:
1. Only accounts billed in the selected reading year and reading period are
   used as the starting population.
2. Account number is formatted as xxxxxx-xxx using cust_no and cust_sequence.
3. Only ACTIVE accounts in ub_master are considered when identifying the
   latest active account.
4. The first connection date is the earliest connect_date found in ub_master
   for the lot.
5. The latest meter is determined by the highest ub_meter_con_id for the lot.
6. Only valid active meters are included:
   - ub_meter_con_id IS NOT NULL
   - ub_device.active = 1
   - ub_meter_con.remove_date IS NULL
   - serial_no does not contain '-S'
7. If @ServiceAddress is NULL or blank, all qualifying records are returned.
   If @ServiceAddress is populated, the results are filtered to that address.

******************************************************************************/

-- ============================================================================
-- PARAMETERS
-- ============================================================================
-- @ReadingYear: billing year to analyze
-- @ReadingPeriod: billing period to analyze
-- @ServiceAddress: optional filter for a single full service address
-- Example:
-- SET @ServiceAddress = '123 MAIN ST MARINA CA 93933';
-- ============================================================================

DECLARE @ReadingYear INT = 2026;
DECLARE @ReadingPeriod INT = 2;
DECLARE @ServiceAddress VARCHAR(200) = NULL;

WITH

-- ============================================================================
-- STEP 1: MeteredAccounts
-- Purpose:
-- Identify the accounts that were actually billed during the selected
-- reading year and period. This becomes the base population for the query.
-- ============================================================================
MeteredAccounts AS (
    SELECT DISTINCT
        h.cust_no,
        h.cust_sequence,

        -- Format account number as xxxxxx-xxx
        RIGHT('000000' + CAST(h.cust_no AS VARCHAR(6)), 6) + '-' +
        RIGHT('000' + CAST(h.cust_sequence AS VARCHAR(3)), 3) AS billed_account_no
    FROM Springbrook0.dbo.ub_meter_hist h
    WHERE h.reading_year = @ReadingYear
      AND h.reading_period = @ReadingPeriod
      AND h.billed = 1
),

-- ============================================================================
-- STEP 2: MeteredLots
-- Purpose:
-- Match billed accounts to ub_master in order to identify the associated
-- lot number. The lot number is the key used to retrieve address history,
-- account history, and meter history.
-- ============================================================================
MeteredLots AS (
    SELECT DISTINCT
        ma.cust_no,
        ma.cust_sequence,
        ma.billed_account_no,
        um.lot_no
    FROM MeteredAccounts ma
    INNER JOIN Springbrook0.dbo.ub_master um
        ON um.cust_no = ma.cust_no
       AND um.cust_sequence = ma.cust_sequence
    WHERE um.lot_no IS NOT NULL
),

-- ============================================================================
-- STEP 3: AddressMatch
-- Purpose:
-- Build a readable service address from the LOT table. This is the service
-- location that will appear in the final result set.
-- ============================================================================
AddressMatch AS (
    SELECT
        l.lot_no,

        -- Build full service address from available address components
        LTRIM(RTRIM(
            COALESCE(CAST(l.street_number AS VARCHAR(20)), '') + ' ' +
            COALESCE(l.street_directional, '') + ' ' +
            COALESCE(l.street_name, '') +
            CASE
                WHEN l.addr_2 IS NOT NULL AND LTRIM(RTRIM(l.addr_2)) <> ''
                    THEN ' ' + l.addr_2
                ELSE ''
            END
        )) AS service_address,

        l.city,
        l.state,
        l.zip
    FROM Springbrook0.dbo.lot l
),

-- ============================================================================
-- STEP 4: FirstConnection
-- Purpose:
-- Determine the earliest known connect_date for each lot. This represents
-- the first time the lot was connected in the system.
-- ============================================================================
FirstConnection AS (
    SELECT
        um.lot_no,
        MIN(um.connect_date) AS first_connection_date
    FROM Springbrook0.dbo.ub_master um
    INNER JOIN MeteredLots ml
        ON um.lot_no = ml.lot_no
    GROUP BY um.lot_no
),

-- ============================================================================
-- STEP 5: ActiveAccounts
-- Purpose:
-- Retrieve all ACTIVE accounts tied to the billed lots. This allows the
-- query to identify the latest active account for the lot.
-- ============================================================================
ActiveAccounts AS (
    SELECT
        um.lot_no,
        um.ub_master_id,
        um.cust_no,
        um.cust_sequence,

        -- Format active account number as xxxxxx-xxx
        RIGHT('000000' + CAST(um.cust_no AS VARCHAR(6)), 6) + '-' +
        RIGHT('000' + CAST(um.cust_sequence AS VARCHAR(3)), 3) AS active_account_no,

        um.connect_date,
        um.final_date
    FROM Springbrook0.dbo.ub_master um
    INNER JOIN MeteredLots ml
        ON um.lot_no = ml.lot_no
    WHERE um.acct_status = 'ACTIVE'
),

-- ============================================================================
-- STEP 6: ActiveAccountSummary
-- Purpose:
-- Summarize all active accounts per lot. This CTE is retained for reference
-- and troubleshooting, even though its fields are not used in the final
-- result set.
-- ============================================================================
ActiveAccountSummary AS (
    SELECT
        aa.lot_no,
        COUNT(*) AS active_account_count,
        STRING_AGG(aa.active_account_no, ', ') AS all_active_accounts
    FROM ActiveAccounts aa
    GROUP BY aa.lot_no
),

-- ============================================================================
-- STEP 7: LatestActiveAccount
-- Purpose:
-- Pick the latest active account for each lot using:
-- 1. most recent connect_date
-- 2. highest ub_master_id as the tie-breaker
-- ============================================================================
LatestActiveAccount AS (
    SELECT
        aa.cust_no,
        aa.cust_sequence,
        aa.lot_no,
        aa.active_account_no,
        aa.connect_date,
        aa.final_date,
        ROW_NUMBER() OVER (
            PARTITION BY aa.lot_no
            ORDER BY aa.connect_date DESC, aa.ub_master_id DESC
        ) AS rn
    FROM ActiveAccounts aa
),

-- ============================================================================
-- STEP 8: LatestActiveMeter
-- Purpose:
-- Pick the latest valid active meter for each lot using the highest
-- ub_meter_con_id.
--
-- Meter filters:
-- - ub_meter_con_id must not be NULL
-- - device must be active
-- - meter connection must not have been removed
-- - serial number must not contain '-S'
-- ============================================================================
LatestActiveMeter AS (
    SELECT
        ml.lot_no,
        mc.ub_meter_con_id,
        mc.ub_device_id,
        mc.install_date,
        mc.location,
        mc.service_point,
        ROW_NUMBER() OVER (
            PARTITION BY ml.lot_no
            ORDER BY mc.ub_meter_con_id DESC
        ) AS rn
    FROM MeteredLots ml
    INNER JOIN Springbrook0.dbo.ub_meter_con mc
        ON ml.lot_no = mc.lot_no
    INNER JOIN Springbrook0.dbo.ub_device ud
        ON mc.ub_device_id = ud.ub_device_id
    WHERE mc.ub_meter_con_id IS NOT NULL
      AND ud.active = 1
      AND mc.remove_date IS NULL
      AND ISNULL(ud.serial_no, '') NOT LIKE '%-S%'
)

-- ============================================================================
-- FINAL RESULT SET
-- Purpose:
-- Return the requested reporting columns only.
-- Date fields are formatted as MM/DD/YYYY.
-- ============================================================================
SELECT
    am.lot_no                                            AS [Lot no],
    am.service_address                                   AS [Service Address],
    am.city                                              AS [City],
    am.state                                             AS [State],
    am.zip                                               AS [Zip Code],

    CONVERT(VARCHAR(10), fc.first_connection_date, 101)  AS [First Connection Date],

    laa.active_account_no                                AS [Latest Active Account],
    CONVERT(VARCHAR(10), laa.connect_date, 101)          AS [Latest Account Start Date],
    CONVERT(VARCHAR(10), laa.final_date, 101)            AS [Latest Account End Date],

    CONVERT(VARCHAR(10), lm.install_date, 101)           AS [Meter Install Date],

    ud.serial_no                                         AS [Meter Serial Number],
    udt.manufacturer                                     AS [Meter Manufacturer],
    udt.model_no                                         AS [Meter Model],
    udt.device_size                                      AS [Meter Size],
    udt.meter_type                                       AS [Meter Type]

FROM MeteredLots ml
INNER JOIN AddressMatch am
    ON ml.lot_no = am.lot_no
LEFT JOIN FirstConnection fc
    ON ml.lot_no = fc.lot_no
LEFT JOIN ActiveAccountSummary aas
    ON ml.lot_no = aas.lot_no
LEFT JOIN LatestActiveAccount laa
    ON ml.lot_no = laa.lot_no
   AND laa.rn = 1
LEFT JOIN LatestActiveMeter lm
    ON ml.lot_no = lm.lot_no
   AND lm.rn = 1
LEFT JOIN Springbrook0.dbo.ub_device ud
    ON lm.ub_device_id = ud.ub_device_id
LEFT JOIN Springbrook0.dbo.ub_device_type udt
    ON ud.ub_device_type_id = udt.ub_device_type_id

-- ============================================================================
-- OPTIONAL ADDRESS FILTER
-- If @ServiceAddress is blank or NULL, return all qualifying records.
-- Otherwise, return only the matching service address.
-- ============================================================================
WHERE
    @ServiceAddress IS NULL
    OR LTRIM(RTRIM(@ServiceAddress)) = ''
    OR UPPER(
        LTRIM(RTRIM(
            am.service_address + ' ' + am.city + ' ' + am.state + ' ' + am.zip
        ))
    ) = UPPER(LTRIM(RTRIM(@ServiceAddress)))

ORDER BY
    [Lot no],
    [Service Address],
    [City],
    [State],
    [Zip Code];