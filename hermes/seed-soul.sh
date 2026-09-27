#!/command/with-contenv sh
set -eu

HERMES_HOME="${HERMES_HOME:-/opt/data}"
mkdir -p "$HERMES_HOME"

# Preserve existing identity and session data on Railway's persistent volume.
if [ ! -f "$HERMES_HOME/SOUL.md" ]; then
  cp /opt/sutra/SOUL.md "$HERMES_HOME/SOUL.md"
fi
