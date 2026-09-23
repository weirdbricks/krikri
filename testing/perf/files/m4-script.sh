#!/bin/sh
# modules_systems.yml's script: payload. Writes a marker file with
# content derived from the arg passed by the play (the run-scoped dir).
target_dir="$1"
printf 'script-ran-with-arg %s\n' "${target_dir}" > "${target_dir}/script-marker.txt"
echo "script stdout marker"
