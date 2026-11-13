#!/usr/bin/env bash
# Run krikri's live PostgreSQL/MySQL integration tests against throwaway
# containers.
#
# Those tests skip silently when nothing is listening on their fixed ports
# (PostgreSQL 127.0.0.1:15432, MySQL 127.0.0.1:33306/33307/33308), which
# means a driver upgrade, a protocol change or a stale registered-shape pin
# can pass CI while never touching a real server. This script brings the
# servers up, waits for them, runs the live suites, and tears the containers
# down again.
#
# The three MySQL servers are the conventions the live specs document:
#   33306  mysql:8.4, stock         - mysql_db/query/info/variables shapes,
#                                     mysql_auth's auth-cache plumbing
#   33307  mariadb:11               - the MariaDB branches (connector auth,
#                                     mysql_user's native-password success
#                                     path, mysql_info's LONGTEXT rewrite)
#   33308  mysql:8.4 with
#          --mysql-native-password=ON - mysql_user's shape specs: with no
#                                     `plugin:` given it hashes the password
#                                     into `IDENTIFIED WITH
#                                     mysql_native_password`, which stock
#                                     MySQL 8.4 rejects (error 1524)
#
# Requires podman (mysql_auth_test.cr uses `podman exec` to flush the
# server's auth cache) and a built bin/ (./build.sh is invoked first).
#
#   scripts/db_tests.sh
#   KRIKRI_KEEP_DB=1 scripts/db_tests.sh   # leave the containers running
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PG_NAME=krikri-db-test-postgres
MY_NAME=krikri-db-test-mysql
NP_NAME=krikri-db-test-mysql-native-password
MDB_NAME=krikri-db-test-mariadb
PG_PORT=15432
MY_PORT=33306
MDB_PORT=33307
NP_PORT=33308
PG_IMAGE=${KRIKRI_PG_IMAGE:-docker.io/library/postgres:17}
MY_IMAGE=${KRIKRI_MY_IMAGE:-docker.io/library/mysql:8.4}
MDB_IMAGE=${KRIKRI_MDB_IMAGE:-docker.io/library/mariadb:11}
CONTAINERS=("$PG_NAME" "$MY_NAME" "$MDB_NAME" "$NP_NAME")

command -v podman >/dev/null 2>&1 || {
  echo "podman is required (mysql_auth_test.cr uses podman exec)" >&2
  exit 1
}

cleanup() {
  if [ "${KRIKRI_KEEP_DB:-0}" = "1" ]; then
    echo "keeping ${CONTAINERS[*]} (KRIKRI_KEEP_DB=1)"
    return
  fi
  podman rm -f "${CONTAINERS[@]}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

podman rm -f "${CONTAINERS[@]}" >/dev/null 2>&1 || true

echo "starting $PG_IMAGE on 127.0.0.1:$PG_PORT"
podman run -d --name "$PG_NAME" \
  -e POSTGRES_PASSWORD=rootpass \
  -p "127.0.0.1:$PG_PORT:5432" \
  "$PG_IMAGE" >/dev/null

echo "starting $MY_IMAGE on 127.0.0.1:$MY_PORT"
podman run -d --name "$MY_NAME" \
  -e MYSQL_ROOT_PASSWORD=krikri \
  -p "127.0.0.1:$MY_PORT:3306" \
  "$MY_IMAGE" >/dev/null

echo "starting $MDB_IMAGE on 127.0.0.1:$MDB_PORT"
podman run -d --name "$MDB_NAME" \
  -e MARIADB_ROOT_PASSWORD=krikri \
  -p "127.0.0.1:$MDB_PORT:3306" \
  "$MDB_IMAGE" >/dev/null

echo "starting $MY_IMAGE (mysql_native_password enabled) on 127.0.0.1:$NP_PORT"
podman run -d --name "$NP_NAME" \
  -e MYSQL_ROOT_PASSWORD=krikri \
  -p "127.0.0.1:$NP_PORT:3306" \
  "$MY_IMAGE" --mysql-native-password=ON >/dev/null

wait_for() {
  local name=$1 deadline=$((SECONDS + 180))
  shift
  until "$@" >/dev/null 2>&1; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "timed out waiting for $name" >&2
      podman logs "$name" | tail -30 >&2 || true
      exit 1
    fi
    sleep 2
  done
}

wait_for "$PG_NAME" podman exec "$PG_NAME" pg_isready -U postgres
wait_for "$MY_NAME" podman exec "$MY_NAME" mysqladmin ping -h 127.0.0.1 -uroot -pkrikri
wait_for "$MDB_NAME" podman exec "$MDB_NAME" mariadb-admin ping -uroot -pkrikri
wait_for "$NP_NAME" podman exec "$NP_NAME" mysqladmin ping -h 127.0.0.1 -uroot -pkrikri

echo "building bin/ (no-op when up to date)"
./build.sh

echo "running PostgreSQL live suite"
scripts/minitest.sh test/integration/postgresql_live_test.cr

echo "running PostgreSQL privileges live suite"
scripts/minitest.sh test/integration/postgresql_privs_live_test.cr

echo "running MySQL auth-cache suite"
scripts/minitest.sh test/integration/mysql_auth_test.cr

echo "running MySQL registered-shape suite"
scripts/minitest.sh test/integration/mysql_result_shape_test.cr

echo "running mysql_variables key-order suite"
scripts/minitest.sh test/integration/key_order_sweep9_test.cr

echo "running mysql_user native-password suite"
scripts/minitest.sh test/integration/mysql_user_native_password_test.cr

echo "running mysql_user salted-auth idempotency suite"
scripts/minitest.sh test/integration/mysql_user_salted_auth_idempotency_test.cr

echo "running mysql_info connector-identity suite"
scripts/minitest.sh test/integration/mysql_info_connector_auth_test.cr

echo "live database tests passed"
