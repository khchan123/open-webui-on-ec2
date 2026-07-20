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


# Copy docker-compose and start
cp "${SCRIPT_DIR}/docker-compose.yaml" "${APP_DIR}/docker-compose.yaml"

cd "${APP_DIR}"
docker compose down --remove-orphans 2>/dev/null || true
docker compose up -d

echo ""
echo "Services started."
echo "  LiteLLM:    http://localhost:4000"
echo "  Open WebUI: http://localhost:80"
echo "  Secrets:    /mnt/app/.env"
