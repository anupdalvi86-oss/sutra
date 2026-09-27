#!/command/with-contenv sh
set -eu

HERMES_HOME="${HERMES_HOME:-/opt/data}"
mkdir -p "$HERMES_HOME"

# Preserve existing identity and session data on Railway's persistent volume.
if [ ! -f "$HERMES_HOME/SOUL.md" ]; then
  cp /opt/sutra/SOUL.md "$HERMES_HOME/SOUL.md"
fi

# The API server can execute its configured Hermes tools. Keep its tool catalog
# intentionally narrow even when an existing persistent config is present.
python3 - "$HERMES_HOME/config.yaml" <<'PY'
import os
import sys
import yaml

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as stream:
        config = yaml.safe_load(stream) or {}
except FileNotFoundError:
    config = {}
if not isinstance(config, dict):
    raise SystemExit("Hermes config must be a YAML mapping")
toolsets = config.get("platform_toolsets")
if toolsets is None:
    toolsets = {}
if not isinstance(toolsets, dict):
    raise SystemExit("Hermes platform_toolsets must be a YAML mapping")
toolsets["api_server"] = ["web"]
config["platform_toolsets"] = toolsets
gateway = config.get("gateway")
if gateway is None:
    gateway = {}
if not isinstance(gateway, dict):
    raise SystemExit("Hermes gateway config must be a YAML mapping")
api_server = gateway.get("api_server")
if api_server is None:
    api_server = {}
if not isinstance(api_server, dict):
    raise SystemExit("Hermes API server config must be a YAML mapping")
api_server["max_concurrent_runs"] = 1
api_server["history_tool_output_max_chars"] = 4000
gateway["api_server"] = api_server
config["gateway"] = gateway
temporary = path + ".sutra.tmp"
with open(temporary, "w", encoding="utf-8") as stream:
    yaml.safe_dump(config, stream, sort_keys=False)
os.chmod(temporary, 0o644)
os.replace(temporary, path)
PY

chown hermes:hermes "$HERMES_HOME/SOUL.md" "$HERMES_HOME/config.yaml"
