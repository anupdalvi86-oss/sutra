#!/bin/sh
set -eu

export HERMES_HOME="${HERMES_HOME:-/opt/data}"
mkdir -p "$HERMES_HOME"

# Seed Sutra identity only on a fresh persistent volume.
if [ ! -f "$HERMES_HOME/SOUL.md" ]; then
  cp /opt/sutra/SOUL.md "$HERMES_HOME/SOUL.md"
fi

# Railway provides PORT. Hermes gateway defaults to 8642.
export HERMES_GATEWAY_PORT="${PORT:-8642}"

exec /opt/hermes/.venv/bin/hermes gateway run
