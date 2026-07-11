 
### 🏛️ PHASE 1: THE MASTER TABLES (Target DDL)

Three new tables are born in your system, each designed for a different data volume and cadence.

```sql
-- 1. Create a dummy application schema
CREATE SCHEMA IF NOT EXISTS app_data;

-- 2. HOURLY Table: High-velocity telemetry data
CREATE TABLE IF NOT EXISTS app_data.telemetry_hourly (
    log_id BIGSERIAL,
    server_ip INET NOT NULL,
    cpu_usage NUMERIC(5,2),
    created_at TIMESTAMPTZ DEFAULT clock_timestamp(),
    PRIMARY KEY (log_id, created_at)
) PARTITION BY RANGE (created_at);

-- 3. DAILY Table: Standard transactional data
CREATE TABLE IF NOT EXISTS app_data.sales_daily (
    transaction_id BIGSERIAL,
    store_id INT NOT NULL,
    amount NUMERIC(15,2) NOT NULL,
    created_at TIMESTAMPTZ DEFAULT clock_timestamp(),
    PRIMARY KEY (transaction_id, created_at)
) PARTITION BY RANGE (created_at);

-- 4. MONTHLY Table: Long-term audit logs
CREATE TABLE IF NOT EXISTS app_data.audit_monthly (
    audit_id BIGSERIAL,
    action_type VARCHAR(50),
    executed_by VARCHAR(50),
    created_at TIMESTAMPTZ DEFAULT clock_timestamp(),
    PRIMARY KEY (audit_id, created_at)
) PARTITION BY RANGE (created_at);


```

---

### 📜 PHASE 2: POLICY INJECTION (The Registration API)

We register the retention and pre-creation rules for each table. Notice how we calibrate the retention based on the interval.

```sql
-- 1. Register HOURLY policy (Retain 2 hours, pre-create current + 2 hours ahead)
SELECT prttb.fn_register_partition_policy(
    p_target_schema      := 'app_data',
    p_target_table       := 'telemetry_hourly',
    p_part_interval      := 'HOURLY',
    p_retention_period   := '2 hours',
    p_pre_create_amount  := 2
);

-- 2. Register DAILY policy (Retain 30 days, pre-create current + 2 days ahead)
SELECT prttb.fn_register_partition_policy(
    p_target_schema      := 'app_data',
    p_target_table       := 'sales_daily',
    p_part_interval      := 'DAILY',
    p_retention_period   := '30 days',
    p_pre_create_amount  := 2
);

-- 3. Register MONTHLY policy (Retain 6 months, pre-create current + 2 months ahead)
SELECT prttb.fn_register_partition_policy(
    p_target_schema      := 'app_data',
    p_target_table       := 'audit_monthly',
    p_part_interval      := 'MONTHLY',
    p_retention_period   := '6 mons',
    p_pre_create_amount  := 2
);


```

### Review of created partitions

```
SELECT
    current_database() AS db_name,
    npar.nspname AS parent_schema,
    cpar.relname AS parent_table,
    nrel.nspname AS child_schema,
    crel.relname AS child_table
FROM pg_class       AS cpar
JOIN pg_namespace   AS npar ON npar.oid = cpar.relnamespace
LEFT JOIN pg_inherits AS i  ON i.inhparent = cpar.oid
LEFT JOIN pg_class     AS crel ON crel.oid = i.inhrelid and  crel.relkind = 'r'
LEFT JOIN pg_namespace AS nrel ON nrel.oid = crel.relnamespace
WHERE cpar.relkind = 'p'  -- only partitioned "parent" tables
and pg_catalog.set_config('client_encoding', current_setting('server_encoding'), true) is not null 
ORDER BY parent_schema, parent_table, child_schema, child_table;

```

**Expected Output:**

```
+---------+---------------+------------------+--------------+--------------------------------+
| db_name | parent_schema |   parent_table   | child_schema |          child_table           |
+---------+---------------+------------------+--------------+--------------------------------+
| test    | app_data      | audit_monthly    | prttb        | audit_monthly_2025_12          |
| test    | app_data      | sales_daily      | prttb        | sales_daily_2026_05_01         |
| test    | app_data      | telemetry_hourly | prttb        | telemetry_hourly_2026_07_11_08 |
+---------+---------------+------------------+--------------+--------------------------------+
(3 rows)

```

---

### 🪤 PHASE 3: THE TRAP (Creation of Expired Partitions)

To put the forensic destroyer of our engine to the test, we will manually create three partitions from the past that already violate the newly created retention policies.

```sql
-- 1. Create an expired HOURLY partition (From 08:00 AM today, retention is only 2 hours)
CREATE TABLE prttb.telemetry_hourly_2026_07_11_08 PARTITION OF app_data.telemetry_hourly 
FOR VALUES FROM ('2026-07-11 08:00:00') TO ('2026-07-11 09:00:00');

-- 2. Create an expired DAILY partition (From May 2026, retention is 30 days)
CREATE TABLE prttb.sales_daily_2026_05_01 PARTITION OF app_data.sales_daily 
FOR VALUES FROM ('2026-05-01') TO ('2026-05-02');

-- 3. Create an expired MONTHLY partition (From December 2025, retention is 6 months)
CREATE TABLE prttb.audit_monthly_2025_12 PARTITION OF app_data.audit_monthly 
FOR VALUES FROM ('2025-12-01') TO ('2026-01-01');


```

---

### ⚙️ PHASE 4: THE AUTONOMOUS ENGINE IN ACTION (pg_cron Simulation)

We execute the engine. We are at July 11, 2026 at 13:00 Hrs. The engine must read the clock, pre-create the present and the future, identify the three trap partitions from Phase 3, and annihilate them without mercy.

```sql
-- Trigger the autonomous maintenance engine (Verbose ON for the lab)
SELECT prttb.fn_maintenance_partitions( p_verbose := TRUE );


```

**Expected Output (Notice Logs):**

```text
NOTICE:  Starting Partition Maintenance Protocol...

-- FUTURE CREATION (HOURLY, DAILY, MONTHLY)
NOTICE:  [CREATED] Partition: prttb.telemetry_hourly_2026_07_11_13
NOTICE:  [CREATED] Partition: prttb.telemetry_hourly_2026_07_11_14
NOTICE:  [CREATED] Partition: prttb.telemetry_hourly_2026_07_11_15
NOTICE:  [CREATED] Partition: prttb.sales_daily_2026_07_11
NOTICE:  [CREATED] Partition: prttb.sales_daily_2026_07_12
NOTICE:  [CREATED] Partition: prttb.sales_daily_2026_07_13
NOTICE:  [CREATED] Partition: prttb.audit_monthly_2026_07
NOTICE:  [CREATED] Partition: prttb.audit_monthly_2026_08
NOTICE:  [CREATED] Partition: prttb.audit_monthly_2026_09

-- PAST PURGE (The Trap has been cleared)
NOTICE:  [DROPPED] Expired Partition: prttb.telemetry_hourly_2026_07_11_08
NOTICE:  [DROPPED] Expired Partition: prttb.sales_daily_2026_05_01
NOTICE:  [DROPPED] Expired Partition: prttb.audit_monthly_2025_12

NOTICE:  Partition Maintenance Protocol Completed.


```

---

### 🧪 PHASE 5: ROUTING TEST (Data Insertion)

We fire data into the master tables using the `clock_timestamp()` function to verify that the PostgreSQL engine routes everything to the newly created partitions.

```sql
-- 1. Insert into HOURLY (Drops into current hour's partition)
INSERT INTO app_data.telemetry_hourly (server_ip, cpu_usage) 
VALUES ('192.168.1.50', 85.5);

-- 2. Insert into DAILY (Drops into today's partition)
INSERT INTO app_data.sales_daily (store_id, amount) 
VALUES (404, 1500.00);

-- 3. Insert into MONTHLY (Drops into this month's partition)
INSERT INTO app_data.audit_monthly (action_type, executed_by) 
VALUES ('LOGIN_SUCCESS', 'admin_sys');


```

*(If you tried to insert a record dated `2025-12-01`, the engine would reject it instantly, protecting the database from storing historical garbage).*

---

### 🔬 PHASE 6: FORENSIC AUDIT (Gatekeeper Review)

We physically validate where the data landed and review the immutable log.

**1. Physical Verification (Exact Routing):**

```sql
-- Check HOURLY routing
SELECT tableoid::regclass AS physical_partition, server_ip, created_at FROM app_data.telemetry_hourly;

-- Check DAILY routing
SELECT tableoid::regclass AS physical_partition, store_id, created_at FROM app_data.sales_daily;

-- Check MONTHLY routing
SELECT tableoid::regclass AS physical_partition, action_type, created_at FROM app_data.audit_monthly;


```

**2. Black Box Verification (Orchestrator Audit):**

```sql
-- Review the partition management log for full traceability (Showing Drops and Creates)
SELECT action_type, target_table, partition_name, date_insert 
FROM prttb.log_partition_management 
ORDER BY id_log DESC LIMIT 5;


```

*Expected Output:*

```text
 action_type |   target_table   |         partition_name          |          date_insert          
-------------+------------------+---------------------------------+-------------------------------
 DROP        | audit_monthly    | audit_monthly_2025_12           | 2026-07-11 13:51:00.123456-07
 DROP        | sales_daily      | sales_daily_2026_05_01          | 2026-07-11 13:51:00.112345-07
 DROP        | telemetry_hourly | telemetry_hourly_2026_07_11_08  | 2026-07-11 13:51:00.101234-07
 CREATE      | audit_monthly    | audit_monthly_2026_09           | 2026-07-11 13:50:59.998877-07
 CREATE      | audit_monthly    | audit_monthly_2026_08           | 2026-07-11 13:50:59.887766-07


```

### 🔬 HEARTBEAT FIRE TEST

Now, if you execute the engine when the future partitions are already created and the old ones are already destroyed, you will see this behavior.

```sql
-- Trigger the autonomous maintenance engine
SELECT prttb.fn_maintenance_partitions( p_verbose := TRUE );


```

**Expected Output (Notice Logs):**

```text
NOTICE:  Starting Partition Maintenance Protocol...
NOTICE:  [HEARTBEAT] No partitions required creation or purging. System is up to date.
NOTICE:  Partition Maintenance Protocol Completed.


```

**Forensic Verification in the Log:**

```sql
SELECT action_type, target_table, partition_name, date_insert
FROM prttb.log_partition_management
ORDER BY id_log DESC LIMIT 1;


```

**Output:**

```text
+-------------+--------------+------------------------+-------------------------------+
| action_type | target_table |     partition_name     |          date_insert          |
+-------------+--------------+------------------------+-------------------------------+
| CHECK_OK    | ALL_POLICIES | NO_PARTITIONS_AFFECTED | 2026-07-11 15:23:48.515658-07 |
+-------------+--------------+------------------------+-------------------------------+
(1 row)


```

---

### 🤖 3. PRODUCTION IMPLEMENTATION (`pg_cron`)

To automate this lethal ecosystem, we inject the directive into `pg_cron`. Since we added `HOURLY` partitioning, the orchestrator's execution must be more aggressive. We will no longer run it once a day, but **once an hour**.

```sql
-- Tactical Schedule: Executes on the 45th minute of every hour, in silent mode (FALSE)
-- Example: 08:45, 09:45, 10:45... This ensures that the partition for the next hour is always ready.
SELECT cron.schedule(
    'partition_maintenance_schedule', 
    '45 * * * *', 
    'SELECT prttb.fn_maintenance_partitions(FALSE);'
);


```
