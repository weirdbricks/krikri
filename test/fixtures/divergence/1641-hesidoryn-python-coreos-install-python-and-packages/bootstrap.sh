#!/bin/bash
# The role's real bootstrap (files/bootstrap.sh in the role tree) downloads the
# long-gone ActivePython 2.7.8.10 tarball with sudo wget and then fails; a
# transcript of that cannot replay (sudo, the network, wget's timestamps and
# DNS ordering are all outside a case). What #1641 turns on is only that the
# script RUNS - the dangling creates: gate does not hold - and exits non-zero,
# so this stands in: deterministic output, same non-zero exit.
echo "bootstrap: the ActivePython 2.7.8.10 tarball is gone; nothing installed" >&2
exit 1
