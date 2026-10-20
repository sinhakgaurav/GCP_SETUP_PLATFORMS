#!/usr/bin/env bash
# One role per VM: kitchcu | enterweu | monitour | wesenseu
# Secrets are sourced from /root/platform.env (mode 600). This script never prints them.
set -u
export GIT_TERMINAL_PROMPT=0
export DEBIAN_FRONTEND=noninteractive
export DOCKER_CLIENT_TIMEOUT=300
export COMPOSE_HTTP_TIMEOUT=300

ROLE="${1:-${ROLE:-}}"
ENV_FILE=/root/platform.env
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

if [ -z "$ROLE" ]; then
  echo "Usage: vm-deploy-all.sh kitchcu|enterweu|monitour|wesenseu" >&2
  exit 2
fi

log() { echo "[$ROLE] $*"; }

retry() {
  local n=0
  until "$@"; do
    n=$((n + 1))
    if [ "$n" -ge 5 ]; then
      return 1
    fi
    log "retry $n"
    sleep $((n * 5))
  done
}

wait_apt() {
  local n=0
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
    n=$((n + 1))
    [ "$n" -gt 24 ] && return 0
    sleep 5
  done
}

install_base() {
  wait_apt || true
  if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    retry apt-get update -y
    retry apt-get install -y ca-certificates curl gnupg git dnsutils openssl
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    . /etc/os-release
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list
    retry apt-get update -y
    retry apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  if ! command -v git >/dev/null 2>&1; then
    retry apt-get update -y
    retry apt-get install -y git curl dnsutils openssl
  fi
  systemctl enable --now docker
  local n=0
  until docker info >/dev/null 2>&1; do
    n=$((n + 1))
    [ "$n" -gt 20 ] && return 1
    sleep 3
  done
  mkdir -p /etc/docker
  if [ ! -f /etc/docker/daemon.json ]; then
    cat > /etc/docker/daemon.json <<'EOF'
{"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}
EOF
    systemctl restart docker
    sleep 3
  fi
  mkdir -p /opt/caddy /root/.ssh
  chmod 700 /root/.ssh
  write_hosts
  if [ "${USE_GIT_SSH:-0}" = "1" ] && [ -f /root/.ssh/id_ed25519 ]; then
    chmod 600 /root/.ssh/id_ed25519
    export GIT_SSH_COMMAND="ssh -i /root/.ssh/id_ed25519 -o StrictHostKeyChecking=accept-new"
    if [ ! -f /root/.ssh/known_hosts ] || ! grep -q github.com /root/.ssh/known_hosts; then
      ssh-keyscan -H github.com >> /root/.ssh/known_hosts 2>/dev/null || true
    fi
  fi
}

ensure_swap() {
  local mb="$1"
  if swapon --show | grep -q /swapfile; then
    return 0
  fi
  if [ ! -f /swapfile ]; then
    fallocate -l "${mb}M" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count="$mb"
  fi
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab
  sysctl -w vm.swappiness=10 >/dev/null || true
  sysctl -w vm.overcommit_memory=1 >/dev/null || true
}

free_gb() {
  df -BG / | awk 'NR==2 {gsub(/G/,"",$4); print $4}'
}

repo_url() {
  local https="$1"
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    printf '%s\n' "https://x-access-token:${GITHUB_TOKEN}@${https#https://}"
    return
  fi
  if [ "${USE_GIT_SSH:-0}" = "1" ] && [ -f /root/.ssh/id_ed25519 ]; then
    local path="${https#https://github.com/}"
    path="${path%.git}"
    printf '%s\n' "git@github.com:${path}.git"
    return
  fi
  printf '%s\n' "$https"
}

update_repo() {
  local dir="$1" public="$2"
  local url
  url=$(repo_url "$public")
  if ! git config --global --get-all safe.directory 2>/dev/null | grep -qx "$dir"; then
    git config --global --add safe.directory "$dir" || true
  fi
  if [ -d "$dir" ] && [ ! -d "$dir/.git" ]; then
    if [ -z "$(ls -A "$dir" 2>/dev/null || true)" ]; then
      rmdir "$dir"
    else
      log "$dir exists and is not a git checkout"
      return 1
    fi
  fi
  if [ -d "$dir/.git" ]; then
    git -C "$dir" remote set-url origin "$url"
    git -C "$dir" fetch origin || return 1
  else
    git clone --depth 1 "$url" "$dir" || return 1
  fi
  if git -C "$dir" show-ref --verify --quiet refs/remotes/origin/main; then
    git -C "$dir" reset --hard origin/main
  elif git -C "$dir" show-ref --verify --quiet refs/remotes/origin/master; then
    git -C "$dir" reset --hard origin/master
  else
    log "no origin/main or origin/master in $dir"
    git -C "$dir" remote set-url origin "$public" || true
    return 1
  fi
  git -C "$dir" remote set-url origin "$public"
}

copy_env_once() {
  local dest="$1" src="$2"
  if [ -f "$dest" ]; then
    return 0
  fi
  if [ ! -f "$src" ]; then
    log "missing env example $src"
    return 1
  fi
  cp "$src" "$dest"
  chmod 600 "$dest"
  log "created $(basename "$dest") from example"
}

publish_env() {
  local src="$1"
  shift
  if [ ! -f "$src" ]; then
    log "compose env source missing: $src"
    return 1
  fi
  chmod 600 "$src"
  local dest
  for dest in "$@"; do
    cp "$src" "$dest"
    chmod 600 "$dest"
  done
}

set_kv() {
  local file="$1" key="$2" value="$3"
  [ -n "$value" ] || return 0
  local tmp
  tmp=$(mktemp)
  grep -v "^${key}=" "$file" > "$tmp" || true
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
  chmod 600 "$file"
}

env_value() {
  local file="$1" key="$2"
  grep "^${key}=" "$file" | head -n 1 | cut -d= -f2- || true
}

fill_placeholder() {
  local file="$1" key="$2"
  local current
  current=$(env_value "$file" "$key")
  case "$current" in
    ""|CHANGE_ME*|wesenseu-change-me*)
      set_kv "$file" "$key" "$(openssl rand -hex 32)"
      ;;
  esac
}

public_ip() {
  curl -sf -H "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip || true
}

write_hosts() {
  sed -i '/# platform-net-begin/,/# platform-net-end/d' /etc/hosts 2>/dev/null || true
  cat >> /etc/hosts <<EOF
# platform-net-begin
${HOST_WESENSEU:-10.20.0.10} wesenseu.internal api.wesenseu.internal
${HOST_KITCHCU:-10.20.0.11} kitchcu.internal api.kitchcu.internal
${HOST_ENTERWEU:-10.20.0.12} enterweu.internal api.enterweu.internal
${HOST_MONITOUR:-10.20.0.13} monitour.internal api.monitour.internal
# platform-net-end
EOF
}

internal_site() {
  local names="$1" api_up="$2" web_up="$3"
  cat <<EOF

# platform-internal
http://${names} {
  encode gzip
  @api path /api/* /oauth/* /health* /docs* /redoc* /openapi.json /media/*
  handle @api {
    reverse_proxy ${api_up}
  }
  handle {
    reverse_proxy ${web_up}
  }
}
EOF
}

dns_ok() {
  local host="$1" ip="$2"
  [ -n "$host" ] && [ -n "$ip" ] || return 1
  local found
  found=$(dig +short "$host" A | head -n 1)
  [ "$found" = "$ip" ]
}

start_caddy() {
  mkdir -p /opt/caddy
  docker volume create caddy_data >/dev/null
  docker volume create caddy_config >/dev/null
  docker rm -f platform-caddy >/dev/null 2>&1 || true
  docker run -d --name platform-caddy --restart unless-stopped \
    --network host \
    -v /opt/caddy/Caddyfile:/etc/caddy/Caddyfile:ro \
    -v caddy_data:/data \
    -v caddy_config:/config \
    caddy:2
}

wait_http() {
  local url="$1"
  local n=0
  while [ "$n" -lt 30 ]; do
    if curl -sf -o /dev/null --max-time 4 "$url"; then
      log "ready $url"
      return 0
    fi
    n=$((n + 1))
    sleep 4
  done
  log "not ready yet: $url"
  return 1
}

compose_up() {
  if "$@"; then
    return 0
  fi
  log "compose failed once; retrying after a short wait"
  sleep 8
  "$@"
}

deploy_wesenseu() {
  ensure_swap 1024
  update_repo /opt/wesenseu https://github.com/sinhakgaurav/wesenseu.git || return 1
  copy_env_once /opt/wesenseu/backend/.env /opt/wesenseu/backend/.env.example || return 1
  local env=/opt/wesenseu/backend/.env
  local ip site api
  ip=$(public_ip)
  fill_placeholder "$env" SECRET_KEY
  set_kv "$env" LOCAL_ONLY "false"
  set_kv "$env" OPENCV_REQUIRED "false"
  set_kv "$env" KITCHCU_API_KEY "${KITCHCU_API_KEY:-}"
  set_kv "$env" ENTERWEU_API_KEY "${ENTERWEU_API_KEY:-}"
  set_kv "$env" MONITOUR_API_KEY "${MONITOUR_API_KEY:-}"
  set_kv "$env" API_KEY "${ENTERWEU_API_KEY:-}"
  set_kv "$env" KITCHCU_OAUTH_CLIENT_SECRET "${KITCHCU_OAUTH_CLIENT_SECRET:-}"
  set_kv "$env" ENTERWEU_OAUTH_CLIENT_SECRET "${ENTERWEU_OAUTH_CLIENT_SECRET:-}"
  set_kv "$env" MONITOUR_OAUTH_CLIENT_SECRET "${MONITOUR_OAUTH_CLIENT_SECRET:-}"
  set_kv "$env" ADMIN_EMAIL "${WESENSEU_ADMIN_EMAIL:-admin@wesenseu.local}"
  set_kv "$env" ADMIN_PASSWORD "${WESENSEU_ADMIN_PASSWORD:-}"
  set_kv "$env" OPENAI_API_KEY "${OPENAI_API_KEY:-}"
  set_kv "$env" GCS_INVOCATION_BUCKET "${GCS_INVOCATION_BUCKET:-}"
  set_kv "$env" INVOCATION_CDN_BASE_URL "${INVOCATION_CDN_BASE_URL:-}"
  set_kv "$env" INVOCATION_CDN_KEY_NAME "${INVOCATION_CDN_KEY_NAME:-}"
  set_kv "$env" INVOCATION_CDN_SIGNING_KEY "${INVOCATION_CDN_SIGNING_KEY:-}"
  set_kv "$env" INVOCATION_CDN_TTL_SECONDS "${INVOCATION_CDN_TTL_SECONDS:-900}"
  set_kv "$env" GOOGLE_MAPS_API_KEY "${GOOGLE_MAPS_API_KEY:-}"
  local internal_names="${HOST_WESENSEU:-10.20.0.10}, wesenseu.internal"
  if [ -n "$ip" ] && dns_ok wesenseu.kitchcu.com "$ip" && dns_ok api.wesenseu.com "$ip"; then
    site="https://wesenseu.kitchcu.com"
    api="https://api.wesenseu.com"
    cat > /opt/caddy/Caddyfile <<EOF
{
  email ${CADDY_EMAIL:-admin@kitchcu.com}
}
wesenseu.kitchcu.com {
  encode gzip
  reverse_proxy 127.0.0.1:3001
}
api.wesenseu.com {
  encode gzip
  reverse_proxy 127.0.0.1:8011
}
$(internal_site "$internal_names" "127.0.0.1:8011" "127.0.0.1:3001")
EOF
  else
    log "WesenseU DNS is not on this VM yet. Caddy serves HTTP on port 80."
    log "Point wesenseu.kitchcu.com and api.wesenseu.com at ${ip:-this VM}, then rerun for HTTPS."
    site="http://${ip}"
    api="http://${ip}"
    cat > /opt/caddy/Caddyfile <<EOF
{
  email ${CADDY_EMAIL:-admin@kitchcu.com}
  auto_https off
}
:80 {
  encode gzip
  @api path /api/* /oauth/* /health* /docs* /redoc* /openapi.json /media/*
  handle @api {
    reverse_proxy 127.0.0.1:8011
  }
  handle {
    reverse_proxy 127.0.0.1:3001
  }
}
$(internal_site "$internal_names" "127.0.0.1:8011" "127.0.0.1:3001")
EOF
  fi
  set_kv "$env" PUBLIC_URL "$site"
  export PUBLIC_URL="$site" MEDIA_PUBLIC_BASE_URL="$api"
  export OPENAI_API_KEY="${OPENAI_API_KEY:-}"
  export KITCHCU_API_KEY="${KITCHCU_API_KEY:-}"
  export ENTERWEU_API_KEY="${ENTERWEU_API_KEY:-}"
  export MONITOUR_API_KEY="${MONITOUR_API_KEY:-}"
  export ADMIN_EMAIL="${WESENSEU_ADMIN_EMAIL:-admin@wesenseu.local}"
  export ADMIN_PASSWORD="${WESENSEU_ADMIN_PASSWORD:-}"
  if [ -n "${CALLBACK_SECRET:-}" ]; then
    set_kv "$env" CALLBACK_SIGNING_SECRET "${CALLBACK_SECRET}"
  fi
  publish_env "$env" /opt/wesenseu/.env || return 1
  compose_up docker compose -p wesenseu --project-directory /opt/wesenseu \
    -f /opt/wesenseu/docker-compose.yml \
    -f /opt/wesenseu/docker-compose.e2.yml \
    up -d --build || return 1
  start_caddy || return 1
  wait_http "http://127.0.0.1:8011/health/live" || return 1
}

deploy_monitour() {
  ensure_swap 2048
  update_repo /opt/monitour https://github.com/sinhakgaurav/monitour.git || return 1
  copy_env_once /opt/monitour/.env.platform /opt/monitour/.env.platform.monitour-only.example || return 1
  local env=/opt/monitour/.env.platform
  set_kv "$env" WESENSEU_ENABLED "false"
  set_kv "$env" KAFKA_ENABLED "false"
  set_kv "$env" WESENSEU_API_URL "${WESENSEU_API_URL:-}"
  set_kv "$env" WESENSEU_API_KEY "${MONITOUR_API_KEY:-}"
  set_kv "$env" GOOGLE_MAPS_API_KEY "${GOOGLE_MAPS_API_KEY:-}"
  publish_env "$env" /opt/monitour/.env || return 1
  compose_up docker compose --project-directory /opt/monitour \
    -f /opt/monitour/docker-compose.platform.yml \
    -f /opt/monitour/docker-compose.monitour-only.yml \
    --env-file "$env" \
    up -d --build || return 1
  local ip
  ip=$(public_ip)
  if [ -n "$ip" ] && dns_ok monitour.in "$ip"; then
    cat > /opt/caddy/Caddyfile <<EOF
{
  email ${CADDY_EMAIL:-admin@kitchcu.com}
}
monitour.in, www.monitour.in {
  encode gzip
  reverse_proxy 127.0.0.1:3000
}
api.monitour.in {
  encode gzip
  reverse_proxy 127.0.0.1:8000
}
$(internal_site "${HOST_MONITOUR:-10.20.0.13}, monitour.internal" "127.0.0.1:8000" "127.0.0.1:3000")
EOF
  else
    log "monitour.in does not point here yet. Caddy stays on HTTP."
    cat > /opt/caddy/Caddyfile <<EOF
{
  email ${CADDY_EMAIL:-admin@kitchcu.com}
  auto_https off
}
:80 {
  encode gzip
  @api path /api/* /health* /docs*
  handle @api {
    reverse_proxy 127.0.0.1:8000
  }
  handle {
    reverse_proxy 127.0.0.1:3000
  }
}
$(internal_site "${HOST_MONITOUR:-10.20.0.13}, monitour.internal" "127.0.0.1:8000" "127.0.0.1:3000")
EOF
  fi
  start_caddy || return 1
  wait_http "http://127.0.0.1:8000/health" || wait_http "http://127.0.0.1:3000/" || return 1
}

deploy_enterweu() {
  ensure_swap 4096
  update_repo /opt/enterweu https://github.com/sinhakgaurav/enterweu.git || return 1
  local override=/tmp/enterweu-host-ports.yml
  if [ ! -f "$override" ]; then
    log "missing $override"
    return 1
  fi
  copy_env_once /opt/enterweu/.env.prod /opt/enterweu/config/env.prod.example || return 1
  local env=/opt/enterweu/.env.prod
  local key
  for key in SECRET_KEY POSTGRES_PASSWORD POSTGRES_LEDGER_PASSWORD POSTGRES_TALENT_PASSWORD INTERNAL_API_KEY; do
    fill_placeholder "$env" "$key"
  done
  if [ -n "${CALLBACK_SECRET:-}" ]; then
    set_kv "$env" WESENSEU_CALLBACK_SECRET "${CALLBACK_SECRET}"
  fi
  case "${WESENSEU_API_URL:-}" in
    ""|http://|https://)
      log "WESENSEU_API_URL is missing. Deploy wesenseu-medium first, then rerun this VM."
      return 1
      ;;
  esac
  if [ -z "${OPENAI_API_KEY:-}" ]; then
    log "OPENAI_API_KEY is empty. Put it in backend/.env or keys.ps1, then rerun. Existing volumes are kept."
    return 1
  fi
  set_kv "$env" WESENSEU_API_URL "${WESENSEU_API_URL:-}"
  set_kv "$env" WESENSEU_API_KEY "${ENTERWEU_API_KEY:-}"
  set_kv "$env" WESENSEU_CALLBACK_URL "${ENTERWEU_PUBLIC_BASE:-https://api.enterweu.com}/api/interviews/wesenseu/callback/"
  set_kv "$env" WESENSEU_ZIP_CALLBACK_URL "${ENTERWEU_PUBLIC_BASE:-https://api.enterweu.com}/api/consultancy/webhooks/zip-analysis/"
  set_kv "$env" WESENSEU_REQUIRE_API_KEY "1"
  set_kv "$env" WESENSEU_REQUIRE_LIVE "0"
  set_kv "$env" OPENAI_API_KEY "${OPENAI_API_KEY:-}"
  publish_env "$env" /opt/enterweu/.env || return 1
  export COMPOSE_PARALLEL_LIMIT=1
  compose_up docker compose -p enterweu --project-directory /opt/enterweu \
    --env-file "$env" \
    -f /opt/enterweu/docker-compose.yml \
    -f /opt/enterweu/docker-compose.prod.yml \
    -f "$override" \
    up -d --build || return 1
  local ip
  ip=$(public_ip)
  if [ -n "$ip" ] && dns_ok enterweu.com "$ip"; then
    cat > /opt/caddy/Caddyfile <<EOF
{
  email ${CADDY_EMAIL:-admin@kitchcu.com}
}
enterweu.com, www.enterweu.com {
  encode gzip
  reverse_proxy 127.0.0.1:3000
}
api.enterweu.com {
  encode gzip
  reverse_proxy 127.0.0.1:8081
}
$(internal_site "${HOST_ENTERWEU:-10.20.0.12}, enterweu.internal" "127.0.0.1:8081" "127.0.0.1:3000")
EOF
  else
    log "enterweu.com does not point here yet. Caddy stays on HTTP."
    cat > /opt/caddy/Caddyfile <<EOF
{
  email ${CADDY_EMAIL:-admin@kitchcu.com}
  auto_https off
}
:80 {
  encode gzip
  @api path /api/* /health*
  handle @api {
    reverse_proxy 127.0.0.1:8081
  }
  handle {
    reverse_proxy 127.0.0.1:3000
  }
}
$(internal_site "${HOST_ENTERWEU:-10.20.0.12}, enterweu.internal" "127.0.0.1:8081" "127.0.0.1:3000")
EOF
  fi
  start_caddy || return 1
  wait_http "http://127.0.0.1:3000/" || return 1
}

write_kitchcu_http_caddy() {
  cat > /opt/ckac/infra/gcp-vm/Caddyfile <<EOF
{
	email ${CADDY_EMAIL:-admin@kitchcu.com}
	auto_https off
}

:80 {
	@customer host customer.kitchcu.com
	handle @customer {
		reverse_proxy customer-web:80
	}
	@kitchen host kitchen.kitchcu.com
	handle @kitchen {
		reverse_proxy kitchen-web:80
	}
	@admin host admin.kitchcu.com
	handle @admin {
		reverse_proxy admin-web:80
	}
	@api host api.kitchcu.com
	handle @api {
		reverse_proxy gateway:8000
	}
	@media host media.kitchcu.com
	handle @media {
		reverse_proxy minio:9000
	}
	handle {
		reverse_proxy portal-web:80
	}
}

http://${HOST_KITCHCU:-10.20.0.11}, kitchcu.internal {
	reverse_proxy gateway:8000
}
EOF
}

deploy_kitchcu() {
  ensure_swap 2048
  update_repo /opt/ckac https://github.com/sinhakgaurav/kitchcu.git || return 1
  copy_env_once /opt/ckac/infra/gcp-vm/.env /opt/ckac/infra/gcp-vm/.env.production.example || return 1
  local env=/opt/ckac/infra/gcp-vm/.env
  set_kv "$env" WESENSEU_API_URL "${WESENSEU_API_URL:-}"
  set_kv "$env" WESENSEU_API_KEY "${KITCHCU_API_KEY:-}"
  set_kv "$env" GOOGLE_MAPS_API_KEY "${GOOGLE_MAPS_API_KEY:-}"
  publish_env "$env" /opt/ckac/.env || return 1
  local ip
  ip=$(public_ip)
  if [ -n "$ip" ] && dns_ok kitchcu.com "$ip"; then
    log "kitchcu.com points here. Using the repo Caddyfile and Let's Encrypt."
    if ! grep -q "kitchcu.internal" /opt/ckac/infra/gcp-vm/Caddyfile; then
      cat >> /opt/ckac/infra/gcp-vm/Caddyfile <<EOF

http://${HOST_KITCHCU:-10.20.0.11}, kitchcu.internal {
	reverse_proxy gateway:8000
}
EOF
    fi
  else
    log "kitchcu.com does not point at ${ip:-this VM}. Serving HTTP so Let's Encrypt is not rate-limited."
    log "The certificate volume is kept. Rerun after the A record exists."
    write_kitchcu_http_caddy
  fi
  bash /opt/ckac/infra/gcp-vm/update-prod.sh --already-updated
}

free=$(free_gb)
if [ "${free:-0}" -lt 8 ]; then
  log "only ${free}GB free on /. The boot disk needs more free space before Docker builds."
  exit 1
fi

install_base || { log "docker install failed"; exit 1; }

case "$ROLE" in
  wesenseu) deploy_wesenseu ;;
  monitour) deploy_monitour ;;
  enterweu) deploy_enterweu ;;
  kitchcu) deploy_kitchcu ;;
  *) echo "Unknown role $ROLE" >&2; exit 2 ;;
esac
rc=$?
ip=$(public_ip)
log "finished exit=$rc external_ip=${ip:-unknown}"
exit "$rc"
