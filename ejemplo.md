
### 🏛️ FASE 1: LAS TABLAS MAESTRAS (Target DDL)

Nacen tres nuevas tablas en tu sistema, cada una diseñada para un volumen y cadencia de datos diferente.

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

### 📜 FASE 2: INYECCIÓN DE LAS POLÍTICAS (El API de Registro)

Registramos las reglas de retención y pre-creación para cada tabla. Observa cómo calibramos la retención en función del intervalo.

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

### Revision de particiones creadas
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
WHERE cpar.relkind = 'p'  -- solo tablas "padre" particionadas
and pg_catalog.set_config('client_encoding', current_setting('server_encoding'), true) is not null 
ORDER BY parent_schema, parent_table, child_schema, child_table;
```


**Salida Esperada:**
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

### 🪤 FASE 3: LA TRAMPA (Creación de Particiones Caducadas)

Para poner a prueba el destructor forense de nuestro motor, vamos a crear manualmente tres particiones del pasado que ya violan las políticas de retención recién creadas.

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

### ⚙️ FASE 4: EL MOTOR AUTÓNOMO EN ACCIÓN (Simulación de pg_cron)

Ejecutamos el motor. Estamos a 11 de Julio de 2026 a las 13:00 Hrs. El motor debe leer el reloj, pre-crear el presente y el futuro, identificar las tres particiones trampas de la Fase 3, y aniquilarlas sin piedad.

```sql
-- Trigger the autonomous maintenance engine (Verbose ON for the lab)
SELECT prttb.fn_maintenance_partitions( p_verbose := TRUE );

```

**Salida Esperada (Notice Logs):**

```text
NOTICE:  Starting Partition Maintenance Protocol...

-- CREACIÓN DEL FUTURO (HOURLY, DAILY, MONTHLY)
NOTICE:  [CREATED] Partition: prttb.telemetry_hourly_2026_07_11_13
NOTICE:  [CREATED] Partition: prttb.telemetry_hourly_2026_07_11_14
NOTICE:  [CREATED] Partition: prttb.telemetry_hourly_2026_07_11_15
NOTICE:  [CREATED] Partition: prttb.sales_daily_2026_07_11
NOTICE:  [CREATED] Partition: prttb.sales_daily_2026_07_12
NOTICE:  [CREATED] Partition: prttb.sales_daily_2026_07_13
NOTICE:  [CREATED] Partition: prttb.audit_monthly_2026_07
NOTICE:  [CREATED] Partition: prttb.audit_monthly_2026_08
NOTICE:  [CREATED] Partition: prttb.audit_monthly_2026_09

-- PURGA DEL PASADO (La Trampa ha sido limpiada)
NOTICE:  [DROPPED] Expired Partition: prttb.telemetry_hourly_2026_07_11_08
NOTICE:  [DROPPED] Expired Partition: prttb.sales_daily_2026_05_01
NOTICE:  [DROPPED] Expired Partition: prttb.audit_monthly_2025_12

NOTICE:  Partition Maintenance Protocol Completed.

```

---

### 🧪 FASE 5: PRUEBA DE ENRUTAMIENTO (Data Insertion)

Le disparamos datos a las tablas maestras utilizando la función `clock_timestamp()` para comprobar que el motor de PostgreSQL rutea todo a las particiones recién creadas.

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

*(Si intentaras insertar un dato con fecha de `2025-12-01`, el motor lo rechazaría al instante, protegiendo a la base de datos de almacenar basura histórica).*

---

### 🔬 FASE 6: AUDITORÍA FORENSE (Gatekeeper Review)

Validamos físicamente dónde cayeron los datos y revisamos la bitácora inmutable.

**1. Verificación Física (Ruteo Exacto):**

```sql
-- Check HOURLY routing
SELECT tableoid::regclass AS physical_partition, server_ip, created_at FROM app_data.telemetry_hourly;

-- Check DAILY routing
SELECT tableoid::regclass AS physical_partition, store_id, created_at FROM app_data.sales_daily;

-- Check MONTHLY routing
SELECT tableoid::regclass AS physical_partition, action_type, created_at FROM app_data.audit_monthly;

```

**2. Verificación de la Caja Negra (Auditoría del Orquestador):**

```sql
-- Review the partition management log for full traceability (Showing Drops and Creates)
SELECT action_type, target_table, partition_name, date_insert 
FROM prttb.log_partition_management 
ORDER BY id_log DESC LIMIT 5;

```

*Salida Esperada:*

```text
 action_type |   target_table   |         partition_name          |          date_insert          
-------------+------------------+---------------------------------+-------------------------------
 DROP        | audit_monthly    | audit_monthly_2025_12           | 2026-07-11 13:51:00.123456-07
 DROP        | sales_daily      | sales_daily_2026_05_01          | 2026-07-11 13:51:00.112345-07
 DROP        | telemetry_hourly | telemetry_hourly_2026_07_11_08  | 2026-07-11 13:51:00.101234-07
 CREATE      | audit_monthly    | audit_monthly_2026_09           | 2026-07-11 13:50:59.998877-07
 CREATE      | audit_monthly    | audit_monthly_2026_08           | 2026-07-11 13:50:59.887766-07

```



### 🔬 PRUEBA DE FUEGO DEL "LATIDO DE VIDA"

Ahora, si ejecutas el motor cuando las particiones futuras ya están creadas y las viejas ya están destruidas, verás este comportamiento.

```sql
-- Trigger the autonomous maintenance engine
SELECT prttb.fn_maintenance_partitions( p_verbose := TRUE );

```

**Salida Esperada (Notice Logs):**

```text
NOTICE:  Starting Partition Maintenance Protocol...
NOTICE:  [HEARTBEAT] No partitions required creation or purging. System is up to date.
NOTICE:  Partition Maintenance Protocol Completed.

```

**Verificación Forense en la Bitácora:**

```sql
SELECT action_type, target_table, partition_name, date_insert
FROM prttb.log_partition_management
ORDER BY id_log DESC LIMIT 1;

```

**Salida:**

```text
+-------------+--------------+------------------------+-------------------------------+
| action_type | target_table |     partition_name     |          date_insert          |
+-------------+--------------+------------------------+-------------------------------+
| CHECK_OK    | ALL_POLICIES | NO_PARTITIONS_AFFECTED | 2026-07-11 15:23:48.515658-07 |
+-------------+--------------+------------------------+-------------------------------+
(1 row)

```
 

---

### 🤖 3. IMPLEMENTACIÓN EN PRODUCCIÓN (`pg_cron`)

Para automatizar este ecosistema letal, inyectamos la directiva en `pg_cron`. Como agregamos el particionamiento `HOURLY`, la ejecución del orquestador debe ser más agresiva. Ya no lo correremos una vez al día, sino **una vez por hora**.

```sql
-- Programación táctica: Se ejecuta en el minuto 45 de cada hora, en modo silencioso (FALSE)
-- Ejemplo: 08:45, 09:45, 10:45... Esto asegura que la partición de la siguiente hora siempre esté lista.
SELECT cron.schedule(
    'mantenimiento_particiones_horario', 
    '45 * * * *', 
    'SELECT prttb.fn_maintenance_partitions(FALSE);'
);

```
