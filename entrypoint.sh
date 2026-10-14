#!/bin/bash
# Container entrypoint:
#   (no args)          -> claude
#   -x / --flag ...    -> claude -x / --flag ...
#   anything else      -> run it as a command (bash, arduino-cli, ...)
set -e

if [ $# -eq 0 ]; then
    exec claude
fi

case "$1" in
    -*) exec claude "$@" ;;
    *)  exec "$@" ;;
esac
