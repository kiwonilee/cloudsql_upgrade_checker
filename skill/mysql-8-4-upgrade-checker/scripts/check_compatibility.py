#!/usr/bin/env python3
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import argparse
import sys
import json

try:
    import pymysql
except ImportError:
    print("Error: PyMySQL library is required to run this checker.")
    print("Please install it using: pip install PyMySQL")
    sys.exit(1)


def parse_arguments():
    parser = argparse.ArgumentParser(
        description="GCP Cloud SQL for MySQL 8.0 to 8.4 Upgrade Compatibility Checker"
    )
    parser.add_argument("--host", required=True, help="MySQL Database Host (IP or Domain)")
    parser.add_argument("--port", type=int, default=3306, help="MySQL Database Port (Default: 3306)")
    parser.add_argument("--user", required=True, help="Database Username")
    parser.add_argument("--password", required=True, help="Database Password")
    parser.add_argument("--database", default=None, help="Database Name (Default: check all databases)")
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")
    return parser.parse_args()


def run_diagnostics(conn, database=None):
    results = {
        "legacy_auth_users": [],
        "spatial_indexes": [],
        "non_utf8mb4_tables": [],
        "table_count": 0,
        "is_safe": True
    }

    with conn.cursor(pymysql.cursors.DictCursor) as cursor:
        # 1. Check legacy auth users (mysql_native_password)
        cursor.execute(
            "SELECT user, host, plugin FROM mysql.user WHERE plugin = 'mysql_native_password';"
        )
        results["legacy_auth_users"] = cursor.fetchall()
        if results["legacy_auth_users"]:
            results["is_safe"] = False

        # 2. Check Spatial Indexes
        spatial_query = (
            "SELECT TABLE_SCHEMA, TABLE_NAME, INDEX_NAME "
            "FROM INFORMATION_SCHEMA.STATISTICS "
            "WHERE INDEX_TYPE = 'SPATIAL'"
        )
        if database:
            spatial_query += f" AND TABLE_SCHEMA = '{database}'"
        else:
            spatial_query += " AND TABLE_SCHEMA NOT IN ('information_schema', 'mysql', 'performance_schema', 'sys')"
        
        cursor.execute(spatial_query)
        results["spatial_indexes"] = cursor.fetchall()
        if results["spatial_indexes"]:
            results["is_safe"] = False

        # 3. Check non-utf8mb4 tables (utf8 / utf8mb3)
        collation_query = (
            "SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_COLLATION "
            "FROM INFORMATION_SCHEMA.TABLES "
            "WHERE TABLE_COLLATION NOT LIKE 'utf8mb4%'"
        )
        if database:
            collation_query += f" AND TABLE_SCHEMA = '{database}'"
        else:
            collation_query += " AND TABLE_SCHEMA NOT IN ('information_schema', 'mysql', 'performance_schema', 'sys')"
            
        cursor.execute(collation_query)
        results["non_utf8mb4_tables"] = cursor.fetchall()

        # 4. Total table count (Cloud SQL limit of 512,000 tables)
        count_query = "SELECT COUNT(*) AS total_tables FROM INFORMATION_SCHEMA.TABLES"
        if database:
            count_query += f" WHERE TABLE_SCHEMA = '{database}'"
        else:
            count_query += " WHERE TABLE_SCHEMA NOT IN ('information_schema', 'mysql', 'performance_schema', 'sys')"
            
        cursor.execute(count_query)
        res = cursor.fetchone()
        results["table_count"] = res["total_tables"] if res else 0
        if results["table_count"] >= 512000:
            results["is_safe"] = False

    return results


def print_markdown_report(results):
    print("# 📊 MySQL 8.0 ➡️ 8.4 Upgrade Compatibility Diagnostic Report\n")
    
    if results["is_safe"]:
        print("🟢 **[PASS]** No critical incompatibility issues found. You can proceed with the upgrade safely.\n")
    else:
        print("🔴 **[WARNING]** Incompatibility issues found that must be resolved before upgrading.\n")

    # 1. Auth Plugin
    print("## 1. 🚨 mysql_native_password Accounts Check")
    if results["legacy_auth_users"]:
        print(f"⚠️ **{len(results['legacy_auth_users'])}** account(s) are using the legacy authentication plugin, which will block client connections after upgrade.")
        print("\n| User | Host | Plugin | Remediation Query |")
        print("|---|---|---|---|")
        for u in results["legacy_auth_users"]:
            user_str = u["user"]
            host_str = u["host"]
            print(f"| {user_str} | {host_str} | {u['plugin']} | `ALTER USER '{user_str}'@'{host_str}' IDENTIFIED WITH caching_sha2_password BY 'new_password';` |")
        print("\n> **Remediation**: Migrate these users to use `caching_sha2_password` or temporarily set the `mysql_native_password=ON` flag after the upgrade.")
    else:
        print("✅ All accounts are using safe authentication plugins.")
    print()

    # 2. Spatial Indexes
    print("## 2. ⚠️ Spatial Indexes Check")
    if results["spatial_indexes"]:
        print(f"⚠️ **{len(results['spatial_indexes'])}** spatial index(es) found. These may cause errors when upgrading to MySQL 8.4.4+.")
        print("\n| Database (Schema) | Table Name | Index Name |")
        print("|---|---|---|")
        for idx in results["spatial_indexes"]:
            print(f"| {idx['TABLE_SCHEMA']} | {idx['TABLE_NAME']} | {idx['INDEX_NAME']} |")
        print("\n> **Remediation**: It is recommended to `DROP` these spatial indexes before the upgrade and restore them with `ADD SPATIAL INDEX` after the upgrade is complete.")
    else:
        print("✅ No spatial indexes found.")
    print()

    # 3. non-utf8mb4 collations
    print("## 3. ⚙️ Character Set & Collation Check")
    if results["non_utf8mb4_tables"]:
        print(f"ℹ️ **{len(results['non_utf8mb4_tables'])}** table(s) are using legacy (e.g., utf8mb3) character sets.")
        print("*(Note: Upgrading will succeed, but migrating them to `utf8mb4` is recommended for future-proof compatibility.)*")
        if len(results["non_utf8mb4_tables"]) > 10:
            print(f"\n*(Showing top 10 of {len(results['non_utf8mb4_tables'])} tables)*")
        print("\n| Database | Table Name | Collation |")
        print("|---|---|---|")
        for tbl in results["non_utf8mb4_tables"][:10]:
            print(f"| {tbl['TABLE_SCHEMA']} | {tbl['TABLE_NAME']} | {tbl['TABLE_COLLATION']} |")
    else:
        print("✅ All tables are using standard utf8mb4-compatible character sets.")
    print()

    # 4. Table Count
    print("## 4. 📊 Cloud SQL Table Count Limit Check")
    count = results["table_count"]
    if count >= 512000:
        print(f"🔴 **[CRITICAL]** Total table count is **{count:,}**. This exceeds or is close to Cloud SQL's major version upgrade limit of 512,000 database objects, which may cause upgrade timeout failures.")
        print("> **Remediation**: Clean up unused tables or merge partitions to reduce the table count to a safe level.")
    else:
        print(f"✅ Total table count is **{count:,}**, which is well below the Cloud SQL safety threshold (512,000 tables).")
    print()


def main():
    args = parse_arguments()

    try:
        connection = pymysql.connect(
            host=args.host,
            port=args.port,
            user=args.user,
            password=args.password,
            charset='utf8mb4'
        )
    except Exception as e:
        if args.json:
            print(json.dumps({"error": f"Failed to connect to MySQL: {str(e)}"}))
        else:
            print(f"❌ [Error] Failed to connect to MySQL: {e}", file=sys.stderr)
        sys.exit(1)

    try:
        diagnostics = run_diagnostics(connection, args.database)
        if args.json:
            print(json.dumps(diagnostics, indent=2))
        else:
            print_markdown_report(diagnostics)
    finally:
        connection.close()


if __name__ == "__main__":
    main()
