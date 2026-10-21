#!/bin/sh
# REST credentials do not cap the lifetime of an already authenticated allocation.
# Terminate the entire TURN process every 120 seconds; old allocations cannot
# survive into the next epoch. Direct connections are unaffected. A relay may
# therefore reconnect at this interval. Do not remove this bound without replacing
# it with tested absolute allocation/traffic enforcement.
set -eu
command -v timeout >/dev/null
trap 'exit 0' INT TERM
while :; do
  set +e
  timeout -s KILL 120 turnserver -c /config/turnserver.conf
  status=$?
  set -e
  case "$status" in
    124|137) ;; # timeout expired; every allocation in that process is gone
    *) exit "$status" ;; # configuration or runtime failure must not spin
  esac
done
