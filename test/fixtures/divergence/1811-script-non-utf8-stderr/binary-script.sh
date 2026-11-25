#!/bin/sh
# The play's script; its bytes are the round's /opt/kpg-fixtures/binary.bin
# (\001 kpgbinary \377), which /bin/sh can only echo back out of a failing
# script rather than being executed as one - the point is the raw non-UTF-8
# byte in the captured stderr, not what the shell made of the file.
printf '\001kpgbinary\377: not found\n' >&2
exit 127
