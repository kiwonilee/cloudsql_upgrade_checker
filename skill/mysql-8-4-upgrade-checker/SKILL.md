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

### 📋 4.1 Detailed Utility Checks
The MySQL Shell Upgrade Checker executes the following automated compatibility checks. AI agents can reference these unique Check IDs to parse and correlate diagnosis results when identifying root causes and recommending remediation paths.

#### Automated Audit Check Registry

| Category | Check ID | Description |
| :--- | :--- | :--- |
| **SQL & Reserved Keywords** | `routineSyntax` | Checks routine (procedures/functions) syntax for conflicts with reserved keywords. |
| | `reservedKeywords` | Checks database object names (tables, columns, etc.) for conflicts with new reserved keywords. |
| | `groupbyAscSyntax` | Checks for obsolete or removed `GROUP BY ASC` or `DESC` syntax usage. |
| | `emptyDotTableSyntax` | Checks for deprecated `.tableName` syntax used in stored routines. |
| | `dollarSignName` | Checks for deprecated usage of single dollar signs ($) in object names. |
| **Data Types & Schemas** | `oldTemporal` | Checks for usage of deprecated temporal type formats. |
| | `utf8mb3` | Checks for usage of the `utf8mb3` character set (`utf8mb4` is recommended). |
| | `enumSetElementLength` | Checks for ENUM/SET column definitions containing elements longer than 255 characters. |
| | `zeroDates` | Checks for invalid zero date, datetime, or timestamp values (`0000-00-00`). |
| | `ftsInTablename` | Checks for table names containing `FTS` (Full-Text Search prefixes), unsupported in 8.0+. |
| | `columnsWhichCannotHaveDefaults` | Checks for columns that cannot have default values (BLOB, TEXT, GEOMETRY, JSON). |
| | `columnDefinition` | Checks for general errors or invalid configurations in column definitions. |
| **Infrastructure & Storage** | `mysqlSchema` | Checks for table names in the `mysql` system schema that conflict with target version tables. |
| | `nonNativePartitioning` | Checks for partitioned tables using non-native partitioning. |
| | `partitionedTablesInSharedTablespaces` | Checks for partitioned tables placed inside shared tablespaces. |
| | `circularDirectory` | Checks for circular directory references in tablespace data file paths. |
| | `schemaInconsistency` | Checks for schema inconsistencies resulting from file removal or corruption. |
| | `engineMixup` | Checks for tables recognized by InnoDB but belonging to a different engine. |
| | `innodbRowFormat` | Checks for InnoDB tables utilizing a non-default row format. |
| **Constraints & Indexes** | `foreignKeyLength` | Checks for foreign key constraint names longer than 64 characters. |
| | `oldGeometryTypes` | Checks for deprecated spatial data columns created in MySQL 5.6. |
| | `indexTooLarge` | Checks for extremely large indexes which are not supported by MySQL 8.0+. |
| | `invalidEngineForeignKey` | Checks for columns with foreign keys pointing to tables from a different storage engine. |
| | `partitionsWithPrefixKeys` | Checks for partitions by key using columns with prefix key indexes. |
| | `foreignKeyReferences` | Checks for foreign keys referencing non-unique and partial indexes. |
| **System Settings & Env** | `maxdbSqlModeFlags` | Checks for usage of the obsolete `sql_mode` flag, `MAXDB`. |
| | `obsoleteSqlModeFlags` | Checks for usage of other obsolete or removed `sql_mode` flags. |
| | `removedFunctions` | Checks for functions which have been completely removed in the target MySQL version. |
| | `removedSysLogVars` | Checks for deprecated system variables used to configure system logging. |
| | `removedSysVars` | Checks for system variables used in the source DB that were removed in the target. |
| | `sysVarsNewDefaults` | Checks for system variables with changed default values (requires `--configPath`). |
| | `sysvarAllowedValues` | Checks system variables for valid value ranges or allowed options. |
| **Security & Plugins** | `defaultAuthenticationPlugin` | Checks for usage of legacy authentication plugins (e.g., `mysql_native_password`). |
| | `defaultAuthenticationPluginMds` | Checks for legacy authentication plugins in use within Metadata Schema (MDS). |
| | `deprecatedDefaultAuth` | Checks for deprecated or invalid default authentication methods in system variables. |
| | `authMethodUsage` | Checks for deprecated or invalid user account authentication methods. |
| | `invalidPrivileges` | Checks for user privileges that will be removed or are no longer valid. |
| | `pluginUsage` | Checks for deprecated, disabled, or removed plugins. |
| **Diagnostics & 5.7 Legacy** | `checkTableCommand` | Checks for issues reported by the `CHECK TABLE ... FOR UPGRADE` command. |
| | `changedFunctionsInGeneratedColumns` | Checks for indexes on functions whose semantics have changed in the target version. |
| | `invalid57Names` | Checks for invalid table and schema names utilized in MySQL 5.7. |
| | `orphanedObjects` | Checks for orphaned routines and events originating from MySQL 5.7. |
| | `deprecatedRouterAuthMethod` | Checks for deprecated/invalid authentication methods used by MySQL Router internal accounts. |
| | `deprecatedTemporalDelimiter` | Checks for deprecated temporal delimiters in table partitions. |

---

### 📊 4.2 JSON Output Structure Reference
When extracting diagnostic reports using the `--output-format=JSON` option, the returned payload utilizes a well-defined tree schema. AI agents must leverage the following keys to accurately parse and process the compatibility report:

```json
{
  "host": "localhost",
  "port": 3306,
  "serverVersion": "8.0.35",
  "targetVersion": "8.4.0",
  "errorCount": 2,
  "warningCount": 5,
  "noticeCount": 1,
  "summary": "2 errors were found. Please correct these issues before upgrading.",
  "checks": [
    {
      "id": "defaultAuthenticationPlugin",
      "name": "Default authentication plugin considerations",
      "status": "ERROR",
      "description": "Checks for older authentication plugins...",
      "documentationLink": "https://dev.mysql.com/doc/refman/8.4/en/...",
      "results": [
        {
          "level": "Error",
          "dbObject": "mysql.user",
          "description": "User 'app_user'@'%' is using deprecated 'mysql_native_password' plugin.",
          "objectType": "User"
        }
      ]
    }
  ],
  "manualChecks": [
    {
      "id": "newDefaults",
      "name": "New default values for system variables",
      "description": "The default values of some system variables have changed...",
      "documentationLink": "https://dev.mysql.com/doc/refman/8.4/en/..."
    }
  ]
}
```

#### JSON Key Schema Definitions

1. **Top-Level Summary Properties**:
   - `host` / `port`: Connection details for the checked MySQL server.
   - `serverVersion`: Detected version of the active source database.
   - `targetVersion`: Intended destination version for the upgrade.
   - `errorCount` / `warningCount` / `noticeCount`: Aggregated tally of found issues.
   - `summary`: High-level textual summary of findings.

2. **Automated Check Registry (`checks` array)**:
   - `id`: Unique identifier matching the automated check keys (e.g., `defaultAuthenticationPlugin`).
   - `name`: Short, human-readable name of the test.
   - `status`: Outcome status, either `OK` or `ERROR`.
   - `description`: Detailed diagnostic summary and advice.
   - `documentationLink`: URL link pointing to the official MySQL Reference Manual.
   - `results` (Array of detailed violations):
     - `level`: Severity level (`Error`, `Warning`, `Notice`).
     - `dbObject`: Fully-qualified database object name affected by the issue.
     - `description`: Detailed, object-specific fact explaining the incompatibility.
     - `objectType`: Structural class of the object (`Schema`, `Table`, `View`, `Column`, `Index`, `ForeignKey`, `Routine`, `Event`, `Trigger`, `SystemVariable`, `User`, `Tablespace`, or `Plugin`).

3. **Manual Verification Registry (`manualChecks` array)**:
   - `id`: Unique identifier for the manual verification step.
   - `name`: Brief description of the manual checklist item.
   - `description`: In-depth manual remediation instructions and guardrails.
   - `documentationLink`: URL link to the official documentation for manual resolution steps.

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
