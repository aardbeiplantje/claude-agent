#!/bin/bash
# Container entrypoint:
#   (no args)          -> claude
#   -x / --flag ...    -> claude -x / --flag ...
#   anything else      -> run it as a command (bash, arduino-cli, ...)
set -e

# Serial device nodes. run.sh sets SERIAL_NODES ("ttyUSB:188 ttyACM:166") and
# allows those majors with a device cgroup rule. Create /dev/<name>0..N-1 so a
# board plugged in (or re-enumerated) later can be opened without a restart.
# A node without a board behind it fails to open with ENXIO.
if [ -n "${SERIAL_NODES:-}" ]; then
    for t in $SERIAL_NODES; do
        name=${t%%:*} major=${t#*:}
        for ((i = 0; i < ${SERIAL_MAX:-8}; i++)); do
            [ -e "/dev/$name$i" ] && continue
            sudo -n mknod -m 0660 "/dev/$name$i" c "$major" "$i" \
                && sudo -n chgrp dialout "/dev/$name$i" \
                || echo "entrypoint: can't create /dev/$name$i" >&2
        done
    done
fi

if [ $# -eq 0 ]; then
    exec claude
fi

case "$1" in
    -*) exec claude "$@" ;;
    *)  exec "$@" ;;
esac
