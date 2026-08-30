#!/usr/bin/env bash
# End-to-end verification of krikri-playbook's crystal-mysql driver fix for
# auth_socket/unix_socket authentication (0.9.340-0.9.343).
#
# Sets up a throwaway MariaDB container where the plugins connect over the
# Unix socket as OS root with NO login_password (the common MariaDB/Debian
# packaging pattern that previously made every mysql_* plugin call fail),
# runs the freshly-built mysql_* plugin binaries against it, and asserts
# each step's PASS/FAIL. Also verifies the new mysql_user `plugin:
# unix_socket` account-creation + idempotency.
#
# Requires: podman (or docker), jq, and `./build.sh` run first so
# bin/plugins/* are fresh. None of the shared ca-mysql/ca-pg test
# containers are touched; a throwaway container is created and removed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG="${1:-docker.io/library/mariadb:11}"
NAME="ca-authsock-$(date +%s)"
SOCKET="/run/mysqld/mysqld.sock"
FAILED=0

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> starting throwaway MariaDB ($IMG) as $NAME"
docker run -d --rm -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 --name "$NAME" "$IMG" >/dev/null

for i in $(seq 1 30); do
  docker exec "$NAME" mariadb -N -e "SELECT 1" >/dev/null 2>&1 && break
  sleep 1
done

echo "==> copying the freshly-built mysql_* plugins into the container"
for p in mysql_db mysql_user mysql_info mysql_query; do
  docker cp "$ROOT/bin/plugins/$p" "$NAME:/tmp/$p"
done

# Run a plugin inside the container as root over the Unix socket, plumbing
# a JSON config on stdin. Prints the plugin's JSON result on stdout.
run_plugin() {
  local plugin="$1"; shift
  local params="$1"
  local config
  config=$(jq -n --argjson params "$params" \
    '{host:{name:"localhost",user:"root",port:22},params:$params,vars:{}}')
  docker exec -u root "$NAME" sh -c "echo '$config' | /tmp/$plugin" 2>/tmp/authsock-plugin-stderr
}

# Runs a plugin and asserts on its reported `failed`/`changed` via jq.
assert_plugin() {
  local desc="$1" plugin="$2" params="$3" expect_failed="$4" expect_changed="$5"
  local out
  out=$(run_plugin "$plugin" "$params")
  local failed changed
  failed=$(echo "$out" | jq -r '.failed')
  changed=$(echo "$out" | jq -r '.changed')
  if [[ "$failed" == "$expect_failed" && "$changed" == "$expect_changed" ]]; then
    echo "PASS  $desc"
  else
    echo "FAIL  $desc  (failed=$failed changed=$changed, expected failed=$expect_failed changed=$expect_changed)"
    echo "      $out"
    FAILED=1
  fi
}

# --- auth_socket: no login_password, connecting as OS root ---
assert_plugin "auth_socket: mysql_db creates a database" mysql_db \
  '{"name":"authsock_test","state":"present","login_user":"root","login_unix_socket":"'$SOCKET'"}' \
  false true

assert_plugin "auth_socket: mysql_db idempotent on rerun" mysql_db \
  '{"name":"authsock_test","state":"present","login_user":"root","login_unix_socket":"'$SOCKET'"}' \
  false false

assert_plugin "auth_socket: mysql_query runs a query" mysql_query \
  '{"login_user":"root","login_unix_socket":"'$SOCKET'","query":"SELECT COUNT(*) AS n FROM mysql.user"}' \
  false false

# --- mysql_user plugin: auth_socket account creation + idempotency ---
assert_plugin "plugin param: create unix_socket auth user" mysql_user \
  '{"name":"sockuser","host":"localhost","plugin":"unix_socket","login_user":"root","login_unix_socket":"'$SOCKET'"}' \
  false true

assert_plugin "plugin param: unix_socket user idempotent on rerun" mysql_user \
  '{"name":"sockuser","host":"localhost","plugin":"unix_socket","login_user":"root","login_unix_socket":"'$SOCKET'"}' \
  false false

assert_plugin "plugin param: unix_socket user removed" mysql_user \
  '{"name":"sockuser","host":"localhost","plugin":"unix_socket","state":"absent","login_user":"root","login_unix_socket":"'$SOCKET'"}' \
  false true

# mysql_info is intentionally not asserted on changed (it's read-only); it
# just needs to connect and report a real server version without failing.
out=$(run_plugin mysql_info '{"login_user":"root","login_unix_socket":"'$SOCKET'"}')
if echo "$out" | jq -e '.failed == false and .version.full != null' >/dev/null 2>&1; then
  ver=$(echo "$out" | jq -r '.version.full')
  echo "PASS  auth_socket: mysql_info connects (server $ver)"
else
  echo "FAIL  auth_socket: mysql_info did not connect: $out"
  FAILED=1
fi

docker rm -f "$NAME" >/dev/null 2>&1  # terminate early, before the trap

echo ""
if [[ "$FAILED" == 0 ]]; then
  echo "AUTH_SOCKET VERIFICATION: ALL PASS"
else
  echo "AUTH_SOCKET VERIFICATION: FAILURES PRESENT"
  exit 1
fi
