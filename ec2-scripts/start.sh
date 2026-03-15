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

# Copy configs if not already present (preserve user edits on re-run)
if [ ! -f "${APP_DIR}/litellm/config.yaml" ]; then
  cp "${SCRIPT_DIR}/litellm-config.yaml" "${APP_DIR}/litellm/config.yaml"
fi
if [ ! -f "${APP_DIR}/prometheus/prometheus.yml" ]; then
  cp "${SCRIPT_DIR}/prometheus.yml" "${APP_DIR}/prometheus/prometheus.yml"
fi

# Generate secrets if not exists (persisted across restarts)
if [ ! -f "${APP_DIR}/.env" ]; then
  cat > "${APP_DIR}/.env" <<EOF
LITELLM_MASTER_KEY=sk-litellm-master-key
WEBUI_SECRET_KEY=$(openssl rand -hex 32)
POSTGRES_PASSWORD=$(openssl rand -hex 16)
EOF
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
