#!/usr/bin/env bash
set -Eeuo pipefail

# n8n + PostgreSQL + AI Assistant Sandbox + SearXNG
# Designed to sit behind an existing Traefik instance on external network "proxy".
# Ubuntu + Docker Compose v2

N8N_DOMAIN="${N8N_DOMAIN:-n8n.cqdxbrasil.com}"
INSTALL_DIR="${INSTALL_DIR:-/opt/apps/n8n}"
PROXY_NETWORK="${PROXY_NETWORK:-proxy}"
N8N_IMAGE="${N8N_IMAGE:-docker.io/n8nio/n8n:latest}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:18-alpine}"
AI_MODEL="${AI_MODEL:-openai/gpt-4.1}"

log(){ printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn(){ printf '\n\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
die(){ printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
randhex(){ openssl rand -hex "$1"; }

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"
command -v docker >/dev/null 2>&1 || die "Docker is not installed. Install the Docker/Traefik stack first."
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required."
docker info >/dev/null 2>&1 || die "Docker daemon is not running."
command -v openssl >/dev/null 2>&1 || die "openssl is required."

docker network inspect "$PROXY_NETWORK" >/dev/null 2>&1 || \
  die "Docker network '$PROXY_NETWORK' does not exist. Install/start Traefik first."

log "Creating n8n installation directory"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

ENV_FILE="$INSTALL_DIR/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  log "Generating secrets"
  umask 077
  cat > "$ENV_FILE" <<EOF
N8N_DOMAIN=${N8N_DOMAIN}
N8N_IMAGE=${N8N_IMAGE}
POSTGRES_IMAGE=${POSTGRES_IMAGE}

# n8n
N8N_ENCRYPTION_KEY=$(randhex 32)
N8N_INSTANCE_AI_MODEL=${AI_MODEL}
# Add your OpenAI API key after installation, then restart n8n.
N8N_INSTANCE_AI_MODEL_API_KEY=

# PostgreSQL
POSTGRES_USER=n8n
POSTGRES_PASSWORD=$(randhex 32)
POSTGRES_DB=n8n

# AI Assistant sandbox - generated secrets
SANDBOX_API_KEYS=$(randhex 32)
SANDBOX_API_RUNNER_REGISTRATION_TOKEN=$(randhex 32)
SANDBOX_API_RUNNER_API_KEY=$(randhex 32)

# SearXNG
SEARXNG_SECRET=$(randhex 32)
N8N_INSTANCE_AI_SEARXNG_URL=http://searxng:8080
EOF
  chmod 600 "$ENV_FILE"
else
  warn "$ENV_FILE already exists; keeping existing secrets/settings."
fi

log "Writing SearXNG configuration"
cat > "$INSTALL_DIR/searxng-settings.yml" <<'EOF'
use_default_settings: true

general:
  debug: false
  instance_name: "n8n SearXNG"

search:
  safe_search: 0
  autocomplete: "duckduckgo"
  formats:
    - html
    - json

server:
  limiter: false
  image_proxy: true
EOF

log "Writing Docker Compose stack"
cat > "$INSTALL_DIR/compose.yaml" <<'EOF'
volumes:
  n8n_data:
    name: n8n_n8n_data
  postgres_data:
    name: n8n_postgres_data
  sandbox_tls:
    name: n8n_sandbox_tls
  sandbox_api_data:
    name: n8n_sandbox_api_data
  searxng_data:
    name: n8n_searxng_data

services:
  postgres:
    image: ${POSTGRES_IMAGE}
    container_name: n8n-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
      PGDATA: /var/lib/postgresql/data
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -h localhost -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 5s
      timeout: 5s
      retries: 10
    networks:
      - internal

  sandbox-certs:
    image: ghcr.io/n8n-io/n8n-sandbox-service-api:latest
    container_name: n8n-sandbox-certs
    user: '0:0'
    entrypoint: ['sh', '-c']
    command:
      - >
        bootstrap-mtls.sh --out-dir /tls --api-san sandbox-api
        --control-san-prefix sandbox-runner --world-readable &&
        chown -R sandbox-api:sandbox-api /tls/api && chmod -R a+rX /tls
    environment:
      NUM_RUNNERS: '1'
    volumes:
      - sandbox_tls:/tls
    networks:
      - internal

  sandbox-api:
    image: ghcr.io/n8n-io/n8n-sandbox-service-api:latest
    container_name: n8n-sandbox-api
    restart: unless-stopped
    depends_on:
      sandbox-certs:
        condition: service_completed_successfully
    environment:
      SANDBOX_API_KEYS: ${SANDBOX_API_KEYS}
      SANDBOX_API_RUNNER_REGISTRATION_TOKEN: ${SANDBOX_API_RUNNER_REGISTRATION_TOKEN}
      SANDBOX_API_RUNNER_API_KEY: ${SANDBOX_API_RUNNER_API_KEY}
      SANDBOX_API_DATA_DIR: /var/lib/n8n-sandbox-api
      SANDBOX_API_GRPC_TLS_CERT_FILE: /tls/api/grpc-server.crt
      SANDBOX_API_GRPC_TLS_KEY_FILE: /tls/api/grpc-server.key
      SANDBOX_API_GRPC_TLS_CLIENT_CA_FILE: /tls/api/ca.crt
      SANDBOX_API_RUNNER_CONTROL_GRPC_TLS_CA_FILE: /tls/api/ca.crt
      SANDBOX_API_RUNNER_CONTROL_GRPC_TLS_CERT_FILE: /tls/api/control-grpc-api-client.crt
      SANDBOX_API_RUNNER_CONTROL_GRPC_TLS_KEY_FILE: /tls/api/control-grpc-api-client.key
      SANDBOX_API_RUNNER_CONTROL_GRPC_TLS_SERVER_NAME: sandbox-runner-1
    volumes:
      - sandbox_tls:/tls:ro
      - sandbox_api_data:/var/lib/n8n-sandbox-api
    healthcheck:
      test: ['CMD', 'wget', '-qO-', 'http://localhost:8080/healthz']
      interval: 5s
      timeout: 3s
      retries: 10
      start_period: 10s
    networks:
      - internal

  sandbox-runner-1:
    image: ghcr.io/n8n-io/n8n-sandbox-service-runner-dind:latest
    container_name: n8n-sandbox-runner-1
    restart: unless-stopped
    privileged: true
    depends_on:
      sandbox-api:
        condition: service_healthy
    environment:
      SANDBOX_RUNNER_API_KEYS: ${SANDBOX_API_RUNNER_API_KEY}
      SANDBOX_RUNNER_REGISTRATION_TOKEN: ${SANDBOX_API_RUNNER_REGISTRATION_TOKEN}
      SANDBOX_RUNNER_API_GRPC_ADDR: sandbox-api:9090
      SANDBOX_RUNNER_HTTP_BASE_URL: http://sandbox-runner-1:8080
      SANDBOX_RUNNER_CONTROL_GRPC_LISTEN_ADDR: ':9091'
      SANDBOX_RUNNER_CONTROL_GRPC_ADVERTISE_ADDR: sandbox-runner-1:9091
      SANDBOX_RUNNER_ID: runner-1
      SANDBOX_RUNNER_DOCKER_SANDBOX_IMAGE: ghcr.io/n8n-io/n8n-sandbox-service-sandbox:latest
      SANDBOX_RUNNER_REGISTRATION_GRPC_CA_FILE: /tls/runner/ca.crt
      SANDBOX_RUNNER_REGISTRATION_GRPC_CERT_FILE: /tls/runner/grpc-client.crt
      SANDBOX_RUNNER_REGISTRATION_GRPC_KEY_FILE: /tls/runner/grpc-client.key
      SANDBOX_RUNNER_REGISTRATION_GRPC_SERVER_NAME: sandbox-api
      SANDBOX_RUNNER_CONTROL_GRPC_TLS_CERT_FILE: /tls/runner/control-grpc-server.crt
      SANDBOX_RUNNER_CONTROL_GRPC_TLS_KEY_FILE: /tls/runner/control-grpc-server.key
      SANDBOX_RUNNER_CONTROL_GRPC_TLS_CLIENT_CA_FILE: /tls/runner/ca.crt
    volumes:
      - sandbox_tls:/tls:ro
    networks:
      - internal

  searxng:
    image: ghcr.io/searxng/searxng:latest
    container_name: n8n-searxng
    restart: unless-stopped
    environment:
      SEARXNG_SECRET: ${SEARXNG_SECRET}
    volumes:
      - ./searxng-settings.yml:/etc/searxng/settings.yml:ro
      - searxng_data:/var/cache/searxng
    networks:
      - internal

  n8n:
    image: ${N8N_IMAGE}
    container_name: n8n
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
      sandbox-api:
        condition: service_healthy
      searxng:
        condition: service_started
    environment:
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: '5432'
      DB_POSTGRESDB_DATABASE: ${POSTGRES_DB}
      DB_POSTGRESDB_USER: ${POSTGRES_USER}
      DB_POSTGRESDB_PASSWORD: ${POSTGRES_PASSWORD}
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
      N8N_HOST: ${N8N_DOMAIN}
      N8N_PROTOCOL: https
      N8N_PORT: '5678'
      N8N_EDITOR_BASE_URL: https://${N8N_DOMAIN}/
      WEBHOOK_URL: https://${N8N_DOMAIN}/
      N8N_PROXY_HOPS: '1'
      GENERIC_TIMEZONE: Europe/London
      TZ: Europe/London
      N8N_SECURE_COOKIE: 'true'
      N8N_ENABLED_MODULES: instance-ai
      N8N_INSTANCE_AI_MODEL: ${N8N_INSTANCE_AI_MODEL}
      N8N_INSTANCE_AI_MODEL_API_KEY: ${N8N_INSTANCE_AI_MODEL_API_KEY}
      N8N_INSTANCE_AI_SANDBOX_ENABLED: 'true'
      N8N_INSTANCE_AI_SANDBOX_IMAGE: ghcr.io/n8n-io/n8n-sandbox-service-sandbox:latest
      N8N_SANDBOX_SERVICE_URL: http://sandbox-api:8080
      N8N_SANDBOX_SERVICE_API_KEY: ${SANDBOX_API_KEYS}
      N8N_INSTANCE_AI_SEARXNG_URL: ${N8N_INSTANCE_AI_SEARXNG_URL}
    volumes:
      - n8n_data:/home/node/.n8n
    networks:
      - internal
      - proxy
    labels:
      - traefik.enable=true
      - 'traefik.http.routers.n8n.rule=Host(`${N8N_DOMAIN}`)'
      - traefik.http.routers.n8n.entrypoints=websecure
      - traefik.http.routers.n8n.tls=true
      - traefik.http.routers.n8n.tls.certresolver=letsencrypt
      - traefik.http.services.n8n.loadbalancer.server.port=5678
      - traefik.docker.network=proxy

networks:
  internal:
    driver: bridge
  proxy:
    external: true
    name: proxy
EOF

log "Validating Compose configuration"
docker compose --env-file "$ENV_FILE" -f "$INSTALL_DIR/compose.yaml" config >/dev/null || \
  die "Docker Compose validation failed."

log "Pulling images"
docker compose --env-file "$ENV_FILE" -f "$INSTALL_DIR/compose.yaml" pull

log "Starting n8n stack"
docker compose --env-file "$ENV_FILE" -f "$INSTALL_DIR/compose.yaml" up -d

log "Waiting for n8n"
for _ in $(seq 1 30); do
  if docker exec n8n wget -qO- http://127.0.0.1:5678/healthz >/dev/null 2>&1; then
    break
  fi
  sleep 3
done

log "Container status"
docker compose --env-file "$ENV_FILE" -f "$INSTALL_DIR/compose.yaml" ps

cat <<EOF

Installation complete.

n8n URL: https://${N8N_DOMAIN}
Install directory: ${INSTALL_DIR}

AI Assistant sandbox: installed
SearXNG web search: installed (internal only)
PostgreSQL: installed (internal only)

OpenAI API key is intentionally NOT stored by this script.
To add it:
  nano ${ENV_FILE}

Set:
  N8N_INSTANCE_AI_MODEL_API_KEY=YOUR_OPENAI_API_KEY

Then restart only n8n:
  cd ${INSTALL_DIR}
  docker compose up -d n8n

Security note:
  sandbox-runner-1 uses privileged Docker-in-Docker, as required by the bundled n8n sandbox stack.
  Do not expose sandbox-api, sandbox-runner, PostgreSQL, or SearXNG ports publicly.
EOF
