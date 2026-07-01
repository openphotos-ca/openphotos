#!/bin/sh
set -eu

umask 002

terminate() {
  for pid in "${OPENPHOTOS_PID:-}" "${RUSTUS_PID:-}"; do
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  done

  wait "${OPENPHOTOS_PID:-}" 2>/dev/null || true
  wait "${RUSTUS_PID:-}" 2>/dev/null || true
}

trap terminate INT TERM HUP

mkdir -p \
  "${DATABASE_PATH}" \
  "${LIBRARY_DIR}" \
  "${RUSTUS_DATA_DIR}" \
  "${RUSTUS_INFO_DIR}"

cd /opt/openphotos

rustus &
RUSTUS_PID=$!

openphotos &
OPENPHOTOS_PID=$!

while :; do
  if ! kill -0 "$OPENPHOTOS_PID" 2>/dev/null; then
    status=0
    wait "$OPENPHOTOS_PID" || status=$?
    kill "$RUSTUS_PID" 2>/dev/null || true
    wait "$RUSTUS_PID" 2>/dev/null || true
    exit "$status"
  fi

  if ! kill -0 "$RUSTUS_PID" 2>/dev/null; then
    status=0
    wait "$RUSTUS_PID" || status=$?
    kill "$OPENPHOTOS_PID" 2>/dev/null || true
    wait "$OPENPHOTOS_PID" 2>/dev/null || true
    exit "$status"
  fi

  sleep 1
done
