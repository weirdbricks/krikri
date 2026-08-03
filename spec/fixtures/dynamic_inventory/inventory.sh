#!/bin/sh
# Minimal dynamic inventory script for the dynamic-inventory integration
# spec - a single "testservers" host, connected locally so this is safe
# to run for real without a second machine to SSH into.
if [ "$1" = "--list" ]; then
  cat <<'JSON'
{
  "testservers": {
    "hosts": ["dynhost1"],
    "vars": {}
  },
  "_meta": {
    "hostvars": {
      "dynhost1": {
        "ansible_connection": "local"
      }
    }
  }
}
JSON
fi
