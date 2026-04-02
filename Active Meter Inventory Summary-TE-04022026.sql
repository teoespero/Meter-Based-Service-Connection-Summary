/******************************************************************************
Author: Teo Espero (IT Administrator)
Date: 04/01/2026

Title:
Meter Inventory Summary

Description:
This query is for meter inventory and is based on all lots with meter
connections, not just billed or read accounts.

It returns:
- Cost Center
- ST Category
- Lot no
- Service Address
- City
- State
- Zip Code
- First Connection Date
- Latest Account
- Latest Account Start Date
- Latest Account End Date
- Meter Install Date
- Meter Serial Number
- Meter Manufacturer
- Meter Model
- Meter Size
- Meter Type

Business Rules:
1. Inventory is based on all lots with meter connections.
2. ST Category comes from lot.misc_2.
3. First Connection Date is the earliest connect_date for the lot.
4. Preferred account logic:
   - use latest ACTIVE account if one exists
   - otherwise use latest connected account
5. Cost Center logic:
   - first use billing_cycle from the preferred account
   - if that is NULL, use billing_cycle from the last ACTIVE account
   - 1 to 4  = Marina
   - 5 to 10 = Ord Community
6. Meter selection uses fallback ranking:
   - first choice: remove_date IS NULL and con_status = 'Active'
   - second choice: con_status = 'Active'
   - third choice: remove_date IS NULL
   - then highest ub_meter_con_id
7. Meters with serial numbers containing '-S' are excluded.
8. Sewer and hydrant services are excluded based on service address text.
9. If @ServiceAddress is NULL or blank, all qualifying records are returned.
   If @ServiceAddress is populated, the results are filtered to that address.

******************************************************************************/

DECLARE @ServiceAddress VARCHAR(200) = NULL;
-- Example:
-- SET @ServiceAddress = '3105 PLEASANT CIRCLE MARINA CA 93933';

WITH

-- STEP 1: All service addresses from lot
AddressMatch AS (
    SELECT
        l.lot_no,
        l.misc_2 AS st_category,
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

-- STEP 2: Earliest known connection date for the lot
FirstConnection AS (
    SELECT
        um.lot_no,
        MIN(um.connect_date) AS first_connection_date
    FROM Springbrook0.dbo.ub_master um
    WHERE um.lot_no IS NOT NULL
    GROUP BY um.lot_no
),

-- STEP 3: All accounts by lot
AllAccounts AS (
    SELECT
        um.lot_no,
        um.ub_master_id,
        um.cust_no,
        um.cust_sequence,
        um.billing_cycle,
        um.acct_status,
        RIGHT('000000' + CAST(um.cust_no AS VARCHAR(6)), 6) + '-' +
        RIGHT('000' + CAST(um.cust_sequence AS VARCHAR(3)), 3) AS account_no,
        um.connect_date,
        um.final_date
    FROM Springbrook0.dbo.ub_master um
    WHERE um.lot_no IS NOT NULL
),

-- STEP 4: Last active account for fallback cost center logic
LastActiveAccount AS (
    SELECT
        aa.lot_no,
        aa.billing_cycle,
        ROW_NUMBER() OVER (
            PARTITION BY aa.lot_no
            ORDER BY aa.connect_date DESC, aa.ub_master_id DESC
        ) AS rn
    FROM AllAccounts aa
    WHERE aa.acct_status = 'ACTIVE'
),

-- STEP 5: Preferred account
-- Latest ACTIVE account if one exists, otherwise latest connected account
PreferredAccount AS (
    SELECT
        aa.lot_no,
        aa.billing_cycle,
        aa.acct_status,
        aa.account_no,
        aa.connect_date,
        aa.final_date,
        ROW_NUMBER() OVER (
            PARTITION BY aa.lot_no
            ORDER BY
                CASE WHEN aa.acct_status = 'ACTIVE' THEN 0 ELSE 1 END,
                aa.connect_date DESC,
                aa.ub_master_id DESC
        ) AS rn
    FROM AllAccounts aa
),

-- STEP 6: Rank all candidate meters by fallback rule
RankedMeters AS (
    SELECT
        mc.lot_no,
        mc.ub_meter_con_id,
        mc.ub_device_id,
        mc.install_date,
        mc.location,
        mc.service_point,
        CASE
            WHEN mc.remove_date IS NULL AND mc.con_status = 'Active' THEN 1
            WHEN mc.con_status = 'Active' THEN 2
            WHEN mc.remove_date IS NULL THEN 3
            ELSE 4
        END AS meter_rank,
        ROW_NUMBER() OVER (
            PARTITION BY mc.lot_no
            ORDER BY
                CASE
                    WHEN mc.remove_date IS NULL AND mc.con_status = 'Active' THEN 1
                    WHEN mc.con_status = 'Active' THEN 2
                    WHEN mc.remove_date IS NULL THEN 3
                    ELSE 4
                END,
                mc.ub_meter_con_id DESC
        ) AS rn
    FROM Springbrook0.dbo.ub_meter_con mc
    INNER JOIN Springbrook0.dbo.ub_device ud
        ON mc.ub_device_id = ud.ub_device_id
    WHERE mc.lot_no IS NOT NULL
      AND mc.ub_meter_con_id IS NOT NULL
      AND ISNULL(ud.serial_no, '') NOT LIKE '%-S%'
      AND UPPER(ISNULL(ud.serial_no, '')) NOT LIKE '%HYDRANT%'
),

-- STEP 7: Best available meter per lot
LatestMeter AS (
    SELECT
        rm.lot_no,
        rm.ub_meter_con_id,
        rm.ub_device_id,
        rm.install_date,
        rm.location,
        rm.service_point,
        rm.meter_rank
    FROM RankedMeters rm
    WHERE rm.rn = 1
)

-- FINAL RESULT
SELECT
    CASE
        WHEN COALESCE(pa.billing_cycle, la.billing_cycle) BETWEEN 1 AND 4 THEN 'Marina'
        WHEN COALESCE(pa.billing_cycle, la.billing_cycle) BETWEEN 5 AND 10 THEN 'Ord Community'
        ELSE 'Unknown'
    END                                                  AS [Cost Center],
    am.st_category                                       AS [ST Category],
    am.lot_no                                            AS [Lot no],
    am.service_address                                   AS [Service Address],
    am.city                                              AS [City],
    am.state                                             AS [State],
    am.zip                                               AS [Zip Code],
    CONVERT(VARCHAR(10), fc.first_connection_date, 101)  AS [First Connection Date],
    pa.account_no                                        AS [Latest Account],
    CONVERT(VARCHAR(10), pa.connect_date, 101)           AS [Latest Account Start Date],
    CONVERT(VARCHAR(10), pa.final_date, 101)             AS [Latest Account End Date],
    CONVERT(VARCHAR(10), lm.install_date, 101)           AS [Meter Install Date],
    ud.serial_no                                         AS [Meter Serial Number],
    udt.manufacturer                                     AS [Meter Manufacturer],
    udt.model_no                                         AS [Meter Model],
    udt.device_size                                      AS [Meter Size],
    udt.meter_type                                       AS [Meter Type]

FROM AddressMatch am
INNER JOIN LatestMeter lm
    ON am.lot_no = lm.lot_no
LEFT JOIN FirstConnection fc
    ON am.lot_no = fc.lot_no
LEFT JOIN PreferredAccount pa
    ON am.lot_no = pa.lot_no
   AND pa.rn = 1
LEFT JOIN LastActiveAccount la
    ON am.lot_no = la.lot_no
   AND la.rn = 1
LEFT JOIN Springbrook0.dbo.ub_device ud
    ON lm.ub_device_id = ud.ub_device_id
LEFT JOIN Springbrook0.dbo.ub_device_type udt
    ON ud.ub_device_type_id = udt.ub_device_type_id

WHERE
    (
        @ServiceAddress IS NULL
        OR LTRIM(RTRIM(@ServiceAddress)) = ''
        OR UPPER(
            LTRIM(RTRIM(
                am.service_address + ' ' + am.city + ' ' + am.state + ' ' + am.zip
            ))
        ) = UPPER(LTRIM(RTRIM(@ServiceAddress)))
    )
    AND UPPER(ISNULL(am.service_address, '')) NOT LIKE '%SEWER%'
    AND UPPER(ISNULL(am.service_address, '')) NOT LIKE '%HYDRANT%'

ORDER BY
    [Cost Center],
    [ST Category],
    [Lot no],
    [Service Address],
    [City],
    [State],
    [Zip Code];