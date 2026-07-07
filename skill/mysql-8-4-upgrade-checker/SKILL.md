---
name: mysql-8-4-upgrade-checker
description: >
  An agent skill to perform compatibility checks and provide migration guides
  for in-place major version upgrades from Cloud SQL for MySQL 8.0 to 8.4 (LTS).
metadata:
  author: DeepMind Advanced Agentic Coding Team
  license: Apache-2.0
  version: 1.0.0
  requires:
    bins:
      - python3
    python:
      - PyMySQL
      - cryptography
---

# Cloud SQL for MySQL 8.4 Upgrade Compatibility Checker Skill

This skill provides comprehensive operational guidelines for AI agents to diagnose upgrade compatibility and safely execute in-place major version upgrades from **Cloud SQL for MySQL 8.0** to **8.4 LTS**.

AI agents (coding assistants) can load this skill to analyze user database environments, suggest robust migration checklists, and run diagnostics scripts to proactively eliminate potential upgrade blockers.

---

## 1. Agent Execution Guidelines

When a user inquires about upgrading MySQL from 8.0 to 8.4 or requests a compatibility audit, activate this skill and perform the following steps:

1. **Recommend Official MySQL Shell Upgrade Checker**:
   - Strongly recommend running Oracle's official `util.checkForServerUpgrade()` utility via MySQL Shell (`mysqlsh`). This is the industry standard that performs an exhaustive, deep check of schema objects, configuration settings, and system values against MySQL 8.4 LTS rules.
2. **Propose Lightweight Custom Diagnostic Script**:
   - Propose running the built-in python diagnostic script `scripts/check_compatibility.py` as a fast, zero-dependency alternative or initial check if installing the full MySQL Shell environment is constrained.
3. **Explain Critical Incompatibilities**:
   - Highlight the **deprecation/disabled status of `mysql_native_password`** which will block clients from connecting after the upgrade. Suggest migrating to `caching_sha2_password`.
4. **Present Cloud SQL-Specific Constraints**:
   - Recommend creating a temporary **Clone Instance** first to perform a safe dry-run upgrade.
   - Emphasize that in-place major version upgrades are **irreversible (non-rollbackable)**, making pre-upgrade backups and testing critical.
5. **Deliver Diagnostic Reports & Remediation Strategies**:
   - Present a clean markdown-formatted audit report based on tool outputs and provide ready-to-run DDL statements (SQL) to resolve issues.

---

## 2. Upgrade Incompatibility Checklist

### 🚨 2.1 Authentication Plugin Changes (Most Critical)
* **Change**: In MySQL 8.4, the legacy `mysql_native_password` authentication plugin is **disabled by default** (and scheduled for complete removal in 9.0).
* **Impact**: Pre-existing users using this plugin will be unable to log in post-upgrade, resulting in `Plugin not loaded` client errors.
* **Diagnosis Query**:
  ```sql
  SELECT user, host, plugin FROM mysql.user WHERE plugin = 'mysql_native_password';
  ```
* **Remediation Steps**:
  - **Recommended**: Migrate accounts to `caching_sha2_password` and update client drivers/connectors to their latest versions:
    ```sql
    ALTER USER 'username'@'host' IDENTIFIED WITH caching_sha2_password BY 'your_password';
    ```
  - **Alternative (Stopgap)**: If connection is lost post-upgrade, temporarily re-enable the plugin via Cloud SQL flags: `mysql_native_password=ON`. Note that this is not a long-term solution.

### ⚠️ 2.2 Deprecated and Removed SQL Functions & Syntax
* **Removal of `WAIT_UNTIL_SQL_THREAD_AFTER_GTIDS()`**:
  - Completely removed in MySQL 8.4. Calling it will trigger a syntax error.
  - **Replacement**: Modify application source code to use `WAIT_FOR_EXECUTED_GTID_SET()`.
* **Spatial Indexes**:
  - Upgrading to MySQL 8.4.4+ might fail if there are existing spatial indexes.
  - **Remediation**: Drop spatial indexes before initiating the upgrade, and recreate them (`ADD SPATIAL INDEX`) after the upgrade is successful.

### ⚙️ 2.3 System Variables & Parameter Defaults
* **Removed Variables**:
  - `innodb_log_file_size` and `innodb_log_files_in_group` are removed and consolidated into `innodb_redo_log_capacity`.
  - `default_authentication_plugin` is completely removed.
* **Changed Defaults**:
  - `innodb_adaptive_hash_index`: `ON` ➡️ `OFF`
  - `innodb_change_buffering`: `all` ➡️ `none` (InnoDB write buffering is disabled by default; evaluate performance impacts).
  - `temptable_use_mmap`: `ON` ➡️ `OFF`
* **Replication Variables Renamed**:
  - All `slave_*` prefixed variables are removed and renamed with `replica_*` prefixes (e.g., `slave_parallel_workers` ➡️ `replica_parallel_workers`). Any legacy `slave_*` flags configured in Cloud SQL must be removed/updated before upgrading, otherwise the upgrade may fail or reject.

---

## 3. Cloud SQL Specific Guide & Best Practices

Managing major version upgrades on Cloud SQL MySQL requires compliance with managed-database-specific guardrails.

### 📋 3.1 Pre-Upgrade Guardrails & Checklist
1. **On-Demand Manual Backup**:
   - While Cloud SQL takes automated backups, always take an on-demand manual backup immediately before the upgrade to ensure a reliable recovery point.
2. **Table & Partition Count Audit**:
   - The total number of tables, partitions, and system objects must be **below 512,000**. Exceeding this threshold can lead to long conversion times and major version upgrade timeouts/failures.
   ```sql
   SELECT COUNT(*) AS total_tables FROM INFORMATION_SCHEMA.TABLES;
   ```
3. **External Replica Breakdown**:
   - In-place major version upgrade cannot be performed on instances participating in external replication. Replication must be stopped and detached first.

### 🧪 3.2 Safe Clone-based Upgrade Testing Process (Strongly Recommended)
Directly upgrading production DBs is highly risky. Guide the user through this isolated testing process:
1. **Clone the Instance**: Create a temporary clone instance from the production instance's latest backup.
2. **Upgrade the Clone**: Perform the in-place major version upgrade (8.0 -> 8.4) on the cloned instance.
3. **End-to-End Compatibility Testing**:
   - Connect the staging/development environment to the upgraded clone.
   - Run integration tests, verify client logins, query performance, and connection driver compatibility.
4. **Execute Production Upgrade**: Schedule the production upgrade and cutover window only after all tests on the clone successfully pass.

---

## 4. Official MySQL Shell Upgrade Checker (Highly Recommended)

The **MySQL Shell Upgrade Checker Utility** (`util.checkForServerUpgrade()`) is the official, Oracle-provided tool for pre-upgrade checks. It performs a comprehensive scan on your target MySQL 8.0 server to identify configuration parameters, schema definitions, and data types that could conflict with MySQL 8.4 LTS.

### ⚙️ How to Run MySQL Shell Upgrade Checker
Ensure you have MySQL Shell (`mysqlsh`) installed on your client machine or bastion host.

#### Option A: Non-Interactive CLI Mode (Recommended for Automation)
You can execute the checker directly from your terminal using the `--execute` flag. This command outputs a clean text report summarizing any errors, warnings, and notice points:

```bash
mysqlsh --host <DB_HOST> \
        --port 3306 \
        --user <USER> \
        --password \
        --execute "util.checkForServerUpgrade({targetVersion: '8.4.0'})"
```
*(Note: Replace `<DB_HOST>` and `<USER>` with your target database details. You will be securely prompted for your password.)*

#### Option B: Interactive Shell Mode
1. Start MySQL Shell:
   ```bash
   mysqlsh
   ```
2. Establish a connection to the target server:
   ```javascript
   \connect <USER>@<DB_HOST>:3306
   ```
3. Run the server upgrade checker function specifying the target version:
   ```javascript
   util.checkForServerUpgrade({targetVersion: "8.4.0"})
   ```

---

## 5. Custom Python Diagnostic Tool (Lightweight Audit)

For restricted environments where installing the full MySQL Shell (`mysqlsh`) package is not possible, this skill includes a lightweight, dependency-free python audit script (`check_compatibility.py`) to run a targeted sanity check.

### 🔍 Execution of `scripts/check_compatibility.py`
Once DB credentials (Host, Port, User, Password) are obtained, invoke the diagnostic script:

```bash
python3 mysql-84-upgrade-checker/scripts/check_compatibility.py \
  --host <DB_HOST> \
  --port 3306 \
  --user <USER> \
  --password <PASSWORD>
```

This custom script instantly scans for:
* Legacy `mysql_native_password` users (Major blocker)
* Outdated collations and character sets
* High table and partition counts (Cloud SQL limits)
* Spatial index constraints
It then generates an actionable, formatted markdown report directly in your agent terminal.
