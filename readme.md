
# 📖 `prttb`: PostgreSQL Partition Engine

## 🎯 What is it and What is it for?

The **Autonomous Partition Management Engine (`prttb`)** is a 100% native, cloud-agnostic framework built entirely in PL/pgSQL. Its purpose is to automate the lifecycle of time-based partitioned tables in PostgreSQL. It acts as a background orchestrator that reads your retention policies, automatically pre-creates future partitions (to ensure zero downtime), and drops expired partitions (to free up storage).

It completely replaces the need for complex, extensions like `pg_partman`.

## 🚀 Key Advantages

* **Cloud-Native & Extension-Free:** No binaries to compile, no server configurations to modify, and no reboots. It works instantly on highly restricted managed clouds like AWS RDS, GCP Cloud SQL, or Azure Database.
* **Set It and Forget It:** Once your policy is defined, the engine runs completely autonomously, eliminating human error during late-night maintenance windows.
* **Zero-Trust Security:** Built with strict schema isolation and revoked `PUBLIC` privileges to prevent SQL injection and privilege escalation.
* **Idempotent Resilience:** Safe to execute multiple times simultaneously. It will not duplicate data or crash; it simply verifies the mathematical state of the catalog and moves on.
* **Total Traceability:** Every action (creation, deletion, or error) is saved in an immutable audit log. It includes a "Heartbeat" mechanism to confirm it is actively running even when no structural changes are required.

## ⚠️ Limitations & Disadvantages

* **Time-Based Only:** Strictly supports `HOURLY`, `DAILY`, and `MONTHLY` chronological routing. It does not support `HASH` or `LIST` partitioning logic.
* **Requires Native Partitioning:** Designed exclusively for PostgreSQL 10+ declarative partitioning. It is incompatible with legacy trigger-based inheritance models.
* **Requires an External Scheduler:** Because it is written in pure SQL, it cannot wake itself up. You must use an external scheduler (like `pg_cron` or an OS-level `cron` job) to trigger the engine.
* **Destructive Purging by Default:** Expired partitions are permanently deleted. If your legal compliance requires archiving data to cold storage (e.g., AWS S3), you must extract it before the retention limit is reached.

## 📊 Real-World Use Cases

* **High-Velocity IoT Telemetry (`HOURLY`):** Manage massive, real-time sensor data or fleet tracking by retaining only the last 24 to 48 hours, preventing RAM and disk saturation.
* **Transactional Ledgers (`DAILY`):** Route high-traffic e-commerce payments by day. Keep active data for 30 to 90 days, allowing lightning-fast analytical queries without scanning cold data.
* **Security & Compliance Logs (`MONTHLY`):** Store corporate audit trails for up to 7 years. The engine will silently drop 7-year-old data while automatically preparing the tables for the upcoming quarter.

## ⚙️ How to Install and Use

Deploying the engine requires zero downtime and consists of three conceptual steps:

1. **Deploy the Core:** Simply import the **`pg_prttb.sql`** file into your database as a superuser. This will automatically create the secure schema, the policy catalogs, and the logic functions.
2. **Register your Policies:** Use the built-in registration API to tell the engine which master table to manage, the time interval, the retention limit, and how far into the future it should pre-create partitions.
3. **Schedule the Automator:** Hook the main maintenance function to your database scheduler. Set it to run once a day (for daily/monthly tables) or once an hour (for hourly tables).

*Note: For a complete, step-by-step walkthrough, expected outputs, and live-fire execution tests, please refer to the **`example_ENG.md`** file included in this repository.*
