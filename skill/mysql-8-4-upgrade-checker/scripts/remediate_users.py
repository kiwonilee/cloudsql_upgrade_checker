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

try:
    import pymysql
except ImportError:
    print("Error: PyMySQL library is required to run this script.")
    print("Please install it using: pip install PyMySQL")
    sys.exit(1)


def parse_arguments():
    parser = argparse.ArgumentParser(
        description="Generates REMEDIATION SQL queries to convert users from mysql_native_password to caching_sha2_password"
    )
    parser.add_argument("--host", required=True, help="MySQL Database Host")
    parser.add_argument("--port", type=int, default=3306, help="MySQL Database Port")
    parser.add_argument("--user", required=True, help="Username")
    parser.add_argument("--password", required=True, help="Password")
    return parser.parse_args()


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
        print(f"❌ [Error] Connection failed: {e}", file=sys.stderr)
        sys.exit(1)

    try:
        with connection.cursor(pymysql.cursors.DictCursor) as cursor:
            cursor.execute(
                "SELECT user, host FROM mysql.user WHERE plugin = 'mysql_native_password';"
            )
            users = cursor.fetchall()

            if not users:
                print("🟢 [INFO] No users are using the `mysql_native_password` plugin! No remediation is required.")
                return

            print(f"📊 [INFO] Detected {len(users)} legacy user(s). Generating remediation SQL script:\n")
            print("```sql")
            print("-- =====================================================================")
            print("-- 🚨 MySQL 8.4 Upgrade: User Authentication Migration Script")
            print("-- =====================================================================")
            print("-- These queries migrate users from mysql_native_password to caching_sha2_password.")
            print("-- Replace 'INPUT_ORIGINAL_PASSWORD' with the actual user passwords before running.")
            print("-- =====================================================================\n")
            for u in users:
                u_name = u["user"]
                h_name = u["host"]
                # Skip system accounts if they occur
                if u_name in ["mysql.sys", "mysql.infoschema", "mysql.session"]:
                    continue
                print(f"ALTER USER '{u_name}'@'{h_name}' IDENTIFIED WITH caching_sha2_password BY 'INPUT_ORIGINAL_PASSWORD';")
            print("\nFLUSH PRIVILEGES;")
            print("```")
            print("\n⚠️ **WARNING**: Copy and execute the queries above in your administrative MySQL client, replacing the placeholder password for each user.")
    finally:
        connection.close()


if __name__ == "__main__":
    main()
