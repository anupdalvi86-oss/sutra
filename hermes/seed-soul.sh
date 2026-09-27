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

# Hermes versions with automatic API_SERVER_KEY generation can start the API
# server even when API_SERVER_ENABLED=false. Keep the platform's explicit
# config flag authoritative, with opt-in requiring a separate Sutra variable.
platforms = config.get("platforms")
if platforms is None:
    platforms = {}
if not isinstance(platforms, dict):
    raise SystemExit("Hermes platforms config must be a YAML mapping")
api_platform = platforms.get("api_server")
if api_platform is None:
    api_platform = {}
if not isinstance(api_platform, dict):
    raise SystemExit("Hermes API server platform config must be a YAML mapping")
enabled = os.environ.get("SUTRA_HERMES_API_ENABLED", "false").strip().lower()
if enabled not in {"true", "false"}:
    raise SystemExit("SUTRA_HERMES_API_ENABLED must be true or false")
api_platform["enabled"] = enabled == "true"
platforms["api_server"] = api_platform
config["platforms"] = platforms

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

# Cost safety for Sutra's API-triggered reviews. The OpenAI-compatible request
# body does not enforce max_tokens, so bound the agent loop and provider retries
# in Hermes' own runtime configuration. A confirmed session model lock is still
# required before a future spend-authorized request is allowed to run.
agent = config.get("agent")
if agent is None:
    agent = {}
if not isinstance(agent, dict):
    raise SystemExit("Hermes agent config must be a YAML mapping")
agent["max_turns"] = 3
agent["api_max_retries"] = 1
agent["auto_recovery_cycles"] = 0
config["agent"] = agent

temporary = path + ".sutra.tmp"
with open(temporary, "w", encoding="utf-8") as stream:
    yaml.safe_dump(config, stream, sort_keys=False)
os.chmod(temporary, 0o644)
os.replace(temporary, path)
PY

chown hermes:hermes "$HERMES_HOME/SOUL.md" "$HERMES_HOME/config.yaml"

# Railway's environment is the source of truth for the private API key. An old
# persisted .env value would otherwise override it when Hermes loads dotenv with
# override=True, silently breaking Sutra's matching client credential.
if [ -f "$HERMES_HOME/.env" ]; then
  python3 - "$HERMES_HOME/.env" <<'PY'
import os
import re
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    lines = stream.readlines()
kept = [line for line in lines if not re.match(r"^\s*(?:export\s+)?API_SERVER_KEY\s*=", line)]
if kept != lines:
    temporary = path + ".sutra.tmp"
    with open(temporary, "w", encoding="utf-8") as stream:
        stream.writelines(kept)
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)
PY
  chown hermes:hermes "$HERMES_HOME/.env"
fi
