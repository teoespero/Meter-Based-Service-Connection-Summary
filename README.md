# Meter-Based-Service-Connection-Summary

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
