BEGIN;

CREATE SCHEMA IF NOT EXISTS prttb;

-- 1. ENUM for Partition Interval (Upgraded with HOURLY support)
CREATE TYPE prttb.partition_interval AS ENUM (
    'HOURLY',
    'DAILY',
    'MONTHLY'
);

-- 2. Partition Policy Control Table 
CREATE TABLE prttb.ctl_partition_policy (
    id_policy SERIAL PRIMARY KEY,
    target_schema VARCHAR(100) NOT NULL,
    target_table VARCHAR(100) NOT NULL,
    part_interval prttb.partition_interval NOT NULL DEFAULT 'MONTHLY',
    retention_period INTERVAL NOT NULL DEFAULT '6 mons',
    pre_create_amount INT NOT NULL DEFAULT 2, -- Hours/Days/Months ahead to pre-create
    date_insert TIMESTAMPTZ DEFAULT clock_timestamp(),
    UNIQUE(target_schema, target_table)
);

-- 3. Unified Partition Management Log 
CREATE TABLE prttb.log_partition_management (
    id_log BIGSERIAL PRIMARY KEY,
    action_type VARCHAR(20) NOT NULL, -- 'CREATE', 'DROP', 'ERROR', 'CHECK_OK'
    target_schema VARCHAR(100) NOT NULL,
    target_table VARCHAR(100) NOT NULL,
    partition_name VARCHAR(200),
    query_executed TEXT,
    error_message TEXT,
    date_insert TIMESTAMPTZ DEFAULT clock_timestamp()
);



-- ==============================================================================
-- FUNCTION: prttb.fn_maintenance_partitions
-- DESCRIPTION: Autonomous engine for HOURLY/DAILY/MONTHLY partition creation and purging.
-- SECURITY: Strictly bound to prttb schema. Revoked from PUBLIC.
-- ==============================================================================
CREATE OR REPLACE FUNCTION prttb.fn_maintenance_partitions(p_verbose BOOLEAN DEFAULT FALSE)
RETURNS VOID 
LANGUAGE plpgsql
SECURITY DEFINER
SET client_min_messages = 'notice'
SET search_path TO prttb, public, pg_temp
AS $$
DECLARE
    rec RECORD;
    v_part_name VARCHAR;
    v_start_time TIMESTAMP;
    v_end_time TIMESTAMP;
    v_dynamic_sql TEXT;
    v_loop_idx INT;
    v_drop_record RECORD;
    
    -- Telemetry counter for the Heartbeat logic
    v_action_count INT := 0; 
BEGIN
    IF p_verbose THEN RAISE NOTICE 'Starting Partition Maintenance Protocol...'; END IF;

    -- [1] PHASE: AUTO-CREATION OF FUTURE PARTITIONS
    FOR rec IN SELECT target_schema, target_table, part_interval, pre_create_amount FROM prttb.ctl_partition_policy LOOP
        
        -- Loop to pre-create N partitions into the future
        FOR v_loop_idx IN 0..rec.pre_create_amount LOOP
            
            IF rec.part_interval = 'MONTHLY' THEN
                v_start_time := DATE_TRUNC('month', CURRENT_TIMESTAMP + (v_loop_idx || ' month')::INTERVAL);
                v_end_time   := v_start_time + INTERVAL '1 month';
                v_part_name  := format('%s_%s', rec.target_table, to_char(v_start_time, 'YYYY_MM'));
                
            ELSIF rec.part_interval = 'DAILY' THEN
                v_start_time := DATE_TRUNC('day', CURRENT_TIMESTAMP + (v_loop_idx || ' day')::INTERVAL);
                v_end_time   := v_start_time + INTERVAL '1 day';
                v_part_name  := format('%s_%s', rec.target_table, to_char(v_start_time, 'YYYY_MM_DD'));
                
            ELSIF rec.part_interval = 'HOURLY' THEN
                v_start_time := DATE_TRUNC('hour', CURRENT_TIMESTAMP + (v_loop_idx || ' hour')::INTERVAL);
                v_end_time   := v_start_time + INTERVAL '1 hour';
                v_part_name  := format('%s_%s', rec.target_table, to_char(v_start_time, 'YYYY_MM_DD_HH24'));
            END IF;

            -- Check if partition already exists in the catalog
            IF NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'prttb' AND c.relname = v_part_name) THEN
                BEGIN
                    v_dynamic_sql := format(
                        'CREATE TABLE prttb.%I PARTITION OF %I.%I FOR VALUES FROM (%L) TO (%L);', 
                        v_part_name, rec.target_schema, rec.target_table, v_start_time, v_end_time
                    );
                    
                    EXECUTE v_dynamic_sql;
                    
                    INSERT INTO prttb.log_partition_management (action_type, target_schema, target_table, partition_name, query_executed)
                    VALUES ('CREATE', rec.target_schema, rec.target_table, v_part_name, v_dynamic_sql);
                    
                    -- Increment action counter
                    v_action_count := v_action_count + 1;
                    
                    IF p_verbose THEN RAISE NOTICE '[CREATED] Partition: prttb.%', v_part_name; END IF;
                EXCEPTION WHEN OTHERS THEN
                    INSERT INTO prttb.log_partition_management (action_type, target_schema, target_table, partition_name, error_message)
                    VALUES ('ERROR', rec.target_schema, rec.target_table, v_part_name, SQLERRM);
                    v_action_count := v_action_count + 1;
                END;
            END IF;
        END LOOP;
    END LOOP;

    -- [2] PHASE: PURGING OF EXPIRED PARTITIONS
    FOR v_drop_record IN 
        SELECT 
            npar.nspname AS parent_schema,
            cpar.relname AS parent_table,
            nrel.nspname AS child_schema,
            crel.relname AS child_table,
            p.part_interval,
            CASE 
                WHEN p.part_interval = 'MONTHLY' THEN to_timestamp(substring(crel.relname FROM '(\d{4}_\d{2})$'), 'YYYY_MM')
                WHEN p.part_interval = 'DAILY'   THEN to_timestamp(substring(crel.relname FROM '(\d{4}_\d{2}_\d{2})$'), 'YYYY_MM_DD')
                WHEN p.part_interval = 'HOURLY'  THEN to_timestamp(substring(crel.relname FROM '(\d{4}_\d{2}_\d{2}_\d{2})$'), 'YYYY_MM_DD_HH24')
            END AS part_timestamp,
            (CURRENT_TIMESTAMP - p.retention_period) AS expiration_timestamp
        FROM pg_inherits i
        JOIN pg_class cpar ON i.inhparent = cpar.oid
        JOIN pg_namespace npar ON cpar.relnamespace = npar.oid
        JOIN pg_class crel ON i.inhrelid = crel.oid
        JOIN pg_namespace nrel ON crel.relnamespace = nrel.oid
        JOIN prttb.ctl_partition_policy p ON npar.nspname = p.target_schema AND cpar.relname = p.target_table
    LOOP
        IF v_drop_record.part_timestamp IS NOT NULL AND v_drop_record.part_timestamp < v_drop_record.expiration_timestamp THEN
            BEGIN
                v_dynamic_sql := format('DROP TABLE %I.%I;', v_drop_record.child_schema, v_drop_record.child_table);
                EXECUTE v_dynamic_sql;
                
                INSERT INTO prttb.log_partition_management (action_type, target_schema, target_table, partition_name, query_executed)
                VALUES ('DROP', v_drop_record.parent_schema, v_drop_record.parent_table, v_drop_record.child_table, v_dynamic_sql);
                
                -- Increment action counter
                v_action_count := v_action_count + 1;
                
                IF p_verbose THEN RAISE NOTICE '[DROPPED] Expired Partition: %.%', v_drop_record.child_schema, v_drop_record.child_table; END IF;
            EXCEPTION WHEN OTHERS THEN
                INSERT INTO prttb.log_partition_management (action_type, target_schema, target_table, partition_name, error_message)
                VALUES ('ERROR', v_drop_record.parent_schema, v_drop_record.parent_table, v_drop_record.child_table, SQLERRM);
                v_action_count := v_action_count + 1;
            END;
        END IF;
    END LOOP;

    -- [3] PHASE: HEARTBEAT LOGGING (If no actions were taken)
    IF v_action_count = 0 THEN
        INSERT INTO prttb.log_partition_management (action_type, target_schema, target_table, partition_name, query_executed)
        VALUES ('CHECK_OK', 'SYSTEM', 'ALL_POLICIES', 'NO_PARTITIONS_AFFECTED', 'Routine maintenance verified all partitions are up to date.');
        
        IF p_verbose THEN RAISE NOTICE '[HEARTBEAT] No partitions required creation or purging. System is up to date.'; END IF;
    END IF;

    IF p_verbose THEN RAISE NOTICE 'Partition Maintenance Protocol Completed.'; END IF;
END;
$$;

REVOKE EXECUTE ON FUNCTION prttb.fn_maintenance_partitions(BOOLEAN) FROM public;



-- ==============================================================================
-- FUNCTION: prttb.fn_register_partition_policy
-- DESCRIPTION: Safely registers or updates a partition policy for a target table.
-- VALIDATION: Cross-references the pg_catalog to ensure the target table is 
--             actually a native partitioned table before accepting the policy.
-- SECURITY: Zero Trust constraints applied. Revoked from PUBLIC.
-- ==============================================================================
-- ==============================================================================
-- FUNCTION: prttb.fn_register_partition_policy (PATCHED)
-- ==============================================================================
CREATE OR REPLACE FUNCTION prttb.fn_register_partition_policy(
    p_target_schema VARCHAR,
    p_target_table VARCHAR,
    p_part_interval prttb.partition_interval DEFAULT 'MONTHLY',
    p_retention_period INTERVAL DEFAULT '6 mons',
    p_pre_create_amount INT DEFAULT 2
) RETURNS TEXT 
LANGUAGE plpgsql
SECURITY DEFINER
SET client_min_messages = 'notice'
SET search_path TO prttb, public, pg_temp
AS $$
DECLARE
    v_is_partitioned BOOLEAN;
BEGIN
    -- [1] Structural Validation
    SELECT EXISTS (
        SELECT 1 
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_catalog.pg_partitioned_table pt ON pt.partrelid = c.oid
        WHERE n.nspname = p_target_schema 
          AND c.relname = p_target_table
    ) INTO v_is_partitioned;

    IF NOT v_is_partitioned THEN
        RAISE EXCEPTION 'VALIDATION FAILED: Table %.% does not exist or is not natively partitioned.', p_target_schema, p_target_table;
    END IF;

    -- [2] Upsert Logic
    INSERT INTO prttb.ctl_partition_policy (
        target_schema, target_table, part_interval, retention_period, pre_create_amount
    ) VALUES (
        p_target_schema, p_target_table, p_part_interval, p_retention_period, p_pre_create_amount
    )
    ON CONFLICT (target_schema, target_table) DO UPDATE 
    SET 
        part_interval = EXCLUDED.part_interval,
        retention_period = EXCLUDED.retention_period,
        pre_create_amount = EXCLUDED.pre_create_amount,
        date_insert = clock_timestamp();

    -- [FIX]: Swapped %.% for %I.%I to comply with PostgreSQL format() rules
    RETURN format('SUCCESS: Partition policy registered/updated for %I.%I', p_target_schema, p_target_table);
END;
$$;


COMMIT;





