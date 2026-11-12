#!/usr/bin/env bash
# Run krikri's live PostgreSQL/MySQL integration tests against throwaway
# containers.
#
# Those tests skip silently when nothing is listening on their fixed ports
# (PostgreSQL 127.0.0.1:15432, MySQL 127.0.0.1:33306), which means a driver
# upgrade or a protocol change can pass CI while never touching a real
# server. This script brings the servers up, waits for them, runs the three
# live suites, and tears the containers down again.
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
PG_PORT=15432
MY_PORT=33306
PG_IMAGE=${KRIKRI_PG_IMAGE:-docker.io/library/postgres:17}
MY_IMAGE=${KRIKRI_MY_IMAGE:-docker.io/library/mysql:8.4}

command -v podman >/dev/null 2>&1 || {
  echo "podman is required (mysql_auth_test.cr uses podman exec)" >&2
  exit 1
}

cleanup() {
  if [ "${KRIKRI_KEEP_DB:-0}" = "1" ]; then
    echo "keeping $PG_NAME and $MY_NAME (KRIKRI_KEEP_DB=1)"
    return
  fi
  podman rm -f "$PG_NAME" "$MY_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

podman rm -f "$PG_NAME" "$MY_NAME" >/dev/null 2>&1 || true

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

echo "building bin/ (no-op when up to date)"
./build.sh

echo "running PostgreSQL live suite"
scripts/minitest.sh test/integration/postgresql_live_test.cr

echo "running PostgreSQL privileges live suite"
scripts/minitest.sh test/integration/postgresql_privs_live_test.cr

echo "running MySQL live suite"
scripts/minitest.sh test/integration/mysql_auth_test.cr

echo "live database tests passed"
