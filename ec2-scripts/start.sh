#!/bin/bash
set -euxo pipefail

# ============================================================================
# start.sh - Start LiteLLM proxy and Open WebUI via docker compose
# Can be re-run to restart services. All persistent data in /mnt/app/
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="/mnt/app"

# Ensure data dirs exist
mkdir -p "${APP_DIR}/litellm"
mkdir -p "${APP_DIR}/open-webui"
mkdir -p "${APP_DIR}/postgres"
mkdir -p "${APP_DIR}/prometheus/data"
chown -R 65534:65534 "${APP_DIR}/prometheus"

# Hermes data dirs (shared by hermes-agent + hermes-webui). Containers run as
# uid/gid 1000 (HERMES_UID / WANTED_UID), so these must be owned by 1000.
mkdir -p "${APP_DIR}/hermes-home/webui"
mkdir -p "${APP_DIR}/hermes-workspace"
chown -R 1000:1000 "${APP_DIR}/hermes-home" "${APP_DIR}/hermes-workspace"

# Always update litellm config (model list changes with deploys)
cp "${SCRIPT_DIR}/litellm-config.yaml" "${APP_DIR}/litellm/config.yaml"

# Copy prometheus config if not already present (preserve user edits)
if [ ! -f "${APP_DIR}/prometheus/prometheus.yml" ]; then
  cp "${SCRIPT_DIR}/prometheus.yml" "${APP_DIR}/prometheus/prometheus.yml"
fi

# Generate secrets if not exists (persisted across restarts)
if [ ! -f "${APP_DIR}/.env" ]; then
  cat > "${APP_DIR}/.env" <<EOF
LITELLM_MASTER_KEY=sk-litellm-master-key
WEBUI_SECRET_KEY=$(openssl rand -hex 32)
POSTGRES_PASSWORD=$(openssl rand -hex 16)
# Bedrock API key for GPT-5.6 models (bedrock-mantle endpoint). Set this to a
# valid Bedrock bearer token to enable the gpt-5.6-* models; leave blank otherwise.
BEDROCK_MANTLE_API_KEY=
EOF
fi

# Ensure BEDROCK_MANTLE_API_KEY exists in pre-existing .env files (added after
# initial provisioning) so docker compose does not warn on the unset variable.
if ! grep -q '^BEDROCK_MANTLE_API_KEY=' "${APP_DIR}/.env"; then
  echo 'BEDROCK_MANTLE_API_KEY=' >> "${APP_DIR}/.env"
fi

# Hermes secrets (added to pre-existing .env files on upgrade):
#   API_SERVER_KEY        - enables the agent gateway API (must be >=16 chars)
#   HERMES_WEBUI_PASSWORD - WebUI login password (it is network-exposed)
if ! grep -q '^API_SERVER_KEY=' "${APP_DIR}/.env"; then
  echo "API_SERVER_KEY=$(openssl rand -hex 24)" >> "${APP_DIR}/.env"
fi
if ! grep -q '^HERMES_WEBUI_PASSWORD=' "${APP_DIR}/.env"; then
  echo "HERMES_WEBUI_PASSWORD=$(openssl rand -hex 12)" >> "${APP_DIR}/.env"
fi

# Seed the Hermes agent config on first run only (preserve manual edits after).
# Render __LITELLM_MASTER_KEY__ from the actual key in .env so the api_key Hermes
# uses to reach LiteLLM always matches, even if the master key was changed.
if [ ! -f "${APP_DIR}/hermes-home/config.yaml" ]; then
  # shellcheck disable=SC1091
  LITELLM_MASTER_KEY=$(grep '^LITELLM_MASTER_KEY=' "${APP_DIR}/.env" | cut -d= -f2-)
  sed "s|__LITELLM_MASTER_KEY__|${LITELLM_MASTER_KEY}|" \
    "${SCRIPT_DIR}/hermes-config.yaml" > "${APP_DIR}/hermes-home/config.yaml"
  chown 1000:1000 "${APP_DIR}/hermes-home/config.yaml"
fi


# Copy docker-compose and start
cp "${SCRIPT_DIR}/docker-compose.yaml" "${APP_DIR}/docker-compose.yaml"

cd "${APP_DIR}"
docker compose down --remove-orphans 2>/dev/null || true
docker compose up -d

echo ""
echo "Services started."
echo "  LiteLLM:      http://localhost:4000"
echo "  Open WebUI:   http://localhost:80"
echo "  Hermes WebUI: http://localhost:8787"
echo "  Secrets:      /mnt/app/.env"
echo "NOTE: hermes-webui installs the agent's Python deps on first boot"
echo "      (uv pip install from PyPI); its first startup can take a few minutes."
