#!/usr/bin/env bash
# One role per VM: kitchcu | enterweu | monitour | wesenseu
# Secrets are sourced from /root/platform.env (mode 600). This script never prints them.
set -u
export GIT_TERMINAL_PROMPT=0
export DEBIAN_FRONTEND=noninteractive
export DOCKER_CLIENT_TIMEOUT=300
export COMPOSE_HTTP_TIMEOUT=300

ROLE="${1:-${ROLE:-}}"
MODE="${2:-${MODE:-full}}"
ENV_FILE=/root/platform.env
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

log() { echo "[${ROLE:-setup}] $*" >&2; }

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
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 \
    && command -v git >/dev/null 2>&1 && command -v dig >/dev/null 2>&1 \
    && docker info >/dev/null 2>&1; then
    log "docker, git, and dig are already installed"
    mkdir -p /opt/caddy /root/.ssh
    chmod 700 /root/.ssh
    write_hosts
    return 0
  fi
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
  if ! command -v git >/dev/null 2>&1 || ! command -v dig >/dev/null 2>&1; then
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
    if ! git clone --depth 1 "$url" "$dir"; then
      log "clone failed for $public"
      if [ -z "${GITHUB_TOKEN:-}" ]; then
        log "GITHUB_TOKEN is empty. Export it in Cloud Shell and rerun setup-all.sh."
      fi
      return 1
    fi
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

http_addrs() {
  local raw="$1" part addr="" oldifs
  oldifs=$IFS
  IFS=','
  for part in $raw; do
    part="${part#"${part%%[![:space:]]*}"}"
    part="${part%"${part##*[![:space:]]}"}"
    [ -n "$part" ] || continue
    case "$part" in
      http://*|https://*) ;;
      *) part="http://${part}" ;;
    esac
    if [ -n "$addr" ]; then
      addr="${addr}, ${part}"
    else
      addr="$part"
    fi
  done
  IFS=$oldifs
  printf '%s' "$addr"
}

internal_site() {
  local names="$1" api_up="$2" web_up="$3"
  local addrs
  addrs=$(http_addrs "$names")
  cat <<EOF

# platform-internal
${addrs} {
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
  local host="$1" ip="$2" found
  [ -n "$host" ] && [ -n "$ip" ] || return 1
  found=$(dig +short @8.8.8.8 "$host" A 2>/dev/null || true)
  printf '%s\n' "$found" | grep -qx "$ip"
}

# Comma-separated names whose public A record is this VM. Others are logged and left off the certificate.
matching_hosts() {
  local ip="$1"
  shift
  local host out=""
  for host in "$@"; do
    if dns_ok "$host" "$ip"; then
      if [ -n "$out" ]; then
        out="${out}, ${host}"
      else
        out="$host"
      fi
    else
      log "HTTPS skipped for ${host}; its A record is not ${ip:-this VM}"
    fi
  done
  printf '%s' "$out"
}

wait_https() {
  local host="$1" n=0 code
  while [ "$n" -lt 18 ]; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
      --resolve "${host}:443:127.0.0.1" "https://${host}/" || true)
    case "$code" in
      2*|3*|4*)
        log "https ready ${host} (${code})"
        return 0
        ;;
    esac
    n=$((n + 1))
    sleep 5
  done
  log "https not ready: ${host}"
  return 1
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
  sleep 3
  if ! docker ps --format '{{.Names}}' | grep -qx platform-caddy; then
    log "platform-caddy exited"
    docker logs platform-caddy 2>&1 | tail -n 40 || true
    return 1
  fi
}

wait_port80() {
  local n=0 code
  while [ "$n" -lt 15 ]; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 http://127.0.0.1/ || true)
    if [ -n "$code" ]; then
      log "port 80 answered ${code}"
      return 0
    fi
    n=$((n + 1))
    sleep 2
  done
  log "port 80 is not accepting connections"
  docker logs platform-caddy 2>&1 | tail -n 40 || true
  return 1
}

wait_auth() {
  local n=0 code=""
  while [ "$n" -lt 30 ]; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8081/api/auth/login/ || true)
    case "$code" in
      200|400|401|403|404|405)
        log "auth gateway answered ${code}"
        return 0
        ;;
    esac
    n=$((n + 1))
    sleep 4
  done
  log "auth gateway still ${code:-down}"
  docker logs --tail 40 enterweu_auth_service 2>&1 || true
  return 1
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

write_role_caddy() {
  local ip="$1" private="$2" api_up="$3" web_up="$4" web_hosts="$5" api_hosts="$6"
  local names="$private"
  if [ -n "$ip" ]; then
    names="${ip}, ${private}"
  fi
  local dest="${CADDY_FILE:-/opt/caddy/Caddyfile}"
  mkdir -p "$(dirname "$dest")"
  if [ -z "$web_hosts" ] && [ -z "$api_hosts" ]; then
    log "No public name points at ${ip:-this VM}. Caddy serves HTTP on port 80."
    cat > "$dest" <<EOF
{
  email ${CADDY_EMAIL:-admin@kitchcu.com}
  auto_https off
}
:80 {
  encode gzip
  @api path /api/* /oauth/* /health* /docs* /redoc* /openapi.json /media/*
  handle @api {
    reverse_proxy ${api_up}
  }
  handle {
    reverse_proxy ${web_up}
  }
}
$(internal_site "$private" "$api_up" "$web_up")
EOF
    return 0
  fi
  log "HTTPS web=[${web_hosts:-none}] api=[${api_hosts:-none}]"
  {
    echo "{"
    echo "  email ${CADDY_EMAIL:-admin@kitchcu.com}"
    echo "}"
    if [ -n "$web_hosts" ]; then
      printf '%s {\n  encode gzip\n  reverse_proxy %s\n}\n' "$web_hosts" "$web_up"
    fi
    if [ -n "$api_hosts" ]; then
      printf '%s {\n  encode gzip\n  reverse_proxy %s\n}\n' "$api_hosts" "$api_up"
    fi
    internal_site "$names" "$api_up" "$web_up"
  } > "$dest"
}

quiet_enterweu() {
  local name
  for name in \
    enterweu_elasticsearch enterweu_mongodb enterweu_zookeeper enterweu_kafka enterweu_kafka_ui \
    enterweu_video_service enterweu_ai_service enterweu_search_service enterweu_event_service \
    enterweu_document_service enterweu_payment_service enterweu_analytics_service \
    enterweu_calendar_service enterweu_outbox_worker
  do
    docker update --restart=no "$name" >/dev/null 2>&1 || true
    docker stop "$name" >/dev/null 2>&1 || true
  done
  log "stopped Elasticsearch, Mongo, Kafka, and the other full-profile services"
}

probe_https_list() {
  local list="$1" host
  [ -n "$list" ] || return 0
  host="${list%%,*}"
  host="${host#"${host%%[![:space:]]*}"}"
  host="${host%"${host##*[![:space:]]}"}"
  if wait_https "$host"; then
    return 0
  fi
  if [ "${PIPELINE:-0}" = "1" ]; then
    log "HTTPS for ${host} is not ready yet. HTTP stays up and setup continues."
    docker logs platform-caddy 2>&1 | tail -n 20 || true
    PIPE_HTTPS="pending"
    return 0
  fi
  return 1
}

deploy_wesenseu() {
  local env=/opt/wesenseu/backend/.env
  if [ "$MODE" = "https" ]; then
    log "HTTPS only. Containers are not rebuilt."
    if [ ! -f "$env" ]; then
      log "No existing install. Run: vm-deploy-all.sh wesenseu"
      return 1
    fi
  else
    ensure_swap 1024
    update_repo /opt/wesenseu https://github.com/sinhakgaurav/wesenseu.git || return 1
    copy_env_once /opt/wesenseu/backend/.env /opt/wesenseu/backend/.env.example || return 1
  fi
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
  local web_hosts api_hosts
  web_hosts=$(matching_hosts "$ip" wesenseu.kitchcu.com)
  api_hosts=$(matching_hosts "$ip" api.wesenseu.com)
  if [ -n "$web_hosts" ]; then
    site="https://wesenseu.kitchcu.com"
  else
    site="http://${ip}"
  fi
  if [ -n "$api_hosts" ]; then
    api="https://api.wesenseu.com"
  else
    api="http://${ip}"
  fi
  write_role_caddy "$ip" "$internal_names" "127.0.0.1:8011" "127.0.0.1:3001" "$web_hosts" "$api_hosts"
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
  if [ "$MODE" != "https" ]; then
    compose_up docker compose -p wesenseu --project-directory /opt/wesenseu \
      -f /opt/wesenseu/docker-compose.yml \
      -f /opt/wesenseu/docker-compose.e2.yml \
      up -d --build || return 1
  fi
  start_caddy || return 1
  wait_port80 || return 1
  wait_http "http://127.0.0.1:8011/health/live" || return 1
  probe_https_list "$web_hosts" || return 1
  probe_https_list "$api_hosts" || return 1
}

deploy_monitour() {
  local env=/opt/monitour/.env.platform
  if [ "$MODE" = "https" ]; then
    log "HTTPS only. Containers are not rebuilt."
    if [ ! -f "$env" ]; then
      log "No existing install. Run: vm-deploy-all.sh monitour"
      return 1
    fi
  else
    ensure_swap 2048
    update_repo /opt/monitour https://github.com/sinhakgaurav/monitour.git || return 1
    copy_env_once /opt/monitour/.env.platform /opt/monitour/.env.platform.monitour-only.example || return 1
  fi
  set_kv "$env" WESENSEU_ENABLED "false"
  set_kv "$env" KAFKA_ENABLED "false"
  set_kv "$env" WESENSEU_API_URL "${WESENSEU_API_URL:-}"
  set_kv "$env" WESENSEU_API_KEY "${MONITOUR_API_KEY:-}"
  set_kv "$env" GOOGLE_MAPS_API_KEY "${GOOGLE_MAPS_API_KEY:-}"
  publish_env "$env" /opt/monitour/.env || return 1
  if [ "$MODE" != "https" ]; then
    compose_up docker compose --project-directory /opt/monitour \
      -f /opt/monitour/docker-compose.platform.yml \
      -f /opt/monitour/docker-compose.monitour-only.yml \
      --env-file "$env" \
      up -d --build || return 1
  fi
  local ip web_hosts api_hosts
  ip=$(public_ip)
  web_hosts=$(matching_hosts "$ip" monitour.in www.monitour.in)
  api_hosts=$(matching_hosts "$ip" api.monitour.in)
  write_role_caddy "$ip" "${HOST_MONITOUR:-10.20.0.13}, monitour.internal" "127.0.0.1:8000" "127.0.0.1:3000" "$web_hosts" "$api_hosts"
  start_caddy || return 1
  wait_port80 || return 1
  wait_http "http://127.0.0.1:8000/health" || wait_http "http://127.0.0.1:3000/" || return 1
  probe_https_list "$web_hosts" || return 1
  probe_https_list "$api_hosts" || return 1
}

deploy_enterweu() {
  local env=/opt/enterweu/.env.prod
  local refresh=0
  if [ "$MODE" = "https" ]; then
    refresh=1
  elif [ "${PIPELINE:-0}" = "1" ] && docker ps -a --format '{{.Names}}' | grep -qx enterweu_auth_service; then
    refresh=1
    log "EnterWeU is already installed. Refreshing containers without an image rebuild."
  fi
  if [ "$refresh" = "1" ]; then
    log "HTTPS only. Containers are not rebuilt."
    if [ ! -f "$env" ]; then
      log "No existing install. Run: vm-deploy-all.sh enterweu"
      return 1
    fi
  else
    ensure_swap 4096
    update_repo /opt/enterweu https://github.com/sinhakgaurav/enterweu.git || return 1
  fi
  local override=/tmp/enterweu-host-ports.yml
  local sibling
  sibling="$(cd "$(dirname "$0")" && pwd)/enterweu-host-ports.yml"
  if [ -f "$sibling" ] && [ "$sibling" != "$override" ]; then
    cp "$sibling" "$override"
  fi
  if [ ! -f "$override" ]; then
    log "missing $override and $sibling"
    return 1
  fi
  if [ "$refresh" != "1" ]; then
    copy_env_once /opt/enterweu/.env.prod /opt/enterweu/config/env.prod.example || return 1
  fi
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
  if [ "$refresh" != "1" ]; then
    if [ "$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)" -ge 7000 ]; then
      export COMPOSE_PROFILES=full
      log "This VM has at least 7 GB. Kafka, Elasticsearch, and Mongo will start."
    else
      log "Under 7 GB. Kafka stays off. Partners call http://10.20.0.10 and receive webhooks on the private network."
    fi
    export COMPOSE_PARALLEL_LIMIT=1
    compose_up docker compose -p enterweu --project-directory /opt/enterweu \
      --env-file "$env" \
      -f /opt/enterweu/docker-compose.yml \
      -f /opt/enterweu/docker-compose.prod.yml \
      -f /tmp/enterweu-host-ports.yml \
      up -d --build || return 1
  else
    docker compose -p enterweu --project-directory /opt/enterweu \
      --env-file "$env" \
      -f /opt/enterweu/docker-compose.yml \
      -f /opt/enterweu/docker-compose.prod.yml \
      -f /tmp/enterweu-host-ports.yml \
      up -d --no-build --force-recreate \
        auth_service user_service interview_service subscription_service \
        consultancy_service admin_service content_service notification_service || return 1
  fi
  if [ "${COMPOSE_PROFILES:-}" != "full" ]; then
    quiet_enterweu
  fi
  wait_auth || return 1
  local ip web_hosts api_hosts
  ip=$(public_ip)
  web_hosts=$(matching_hosts "$ip" enterweu.com www.enterweu.com)
  api_hosts=$(matching_hosts "$ip" api.enterweu.com)
  write_role_caddy "$ip" "${HOST_ENTERWEU:-10.20.0.12}, enterweu.internal" "127.0.0.1:8081" "127.0.0.1:3000" "$web_hosts" "$api_hosts"
  start_caddy || return 1
  wait_port80 || return 1
  wait_http "http://127.0.0.1:3000/" || return 1
  probe_https_list "$web_hosts" || return 1
  probe_https_list "$api_hosts" || return 1
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

$(http_addrs "${HOST_KITCHCU:-10.20.0.11}, kitchcu.internal") {
	reverse_proxy gateway:8000
}
EOF
}

write_kitchcu_caddy() {
  local ip="$1"
  local hosts
  hosts=$(matching_hosts "$ip" kitchcu.com www.kitchcu.com customer.kitchcu.com kitchen.kitchcu.com admin.kitchcu.com api.kitchcu.com media.kitchcu.com)
  KITCHCU_HTTPS_HOST=""
  if [ -z "$hosts" ]; then
    log "No kitchCU name points at ${ip:-this VM}. Serving HTTP so Let's Encrypt is not rate-limited."
    write_kitchcu_http_caddy
    return 0
  fi
  KITCHCU_HTTPS_HOST="${hosts%%,*}"
  KITCHCU_HTTPS_HOST="${KITCHCU_HTTPS_HOST#"${KITCHCU_HTTPS_HOST%%[![:space:]]*}"}"
  KITCHCU_HTTPS_HOST="${KITCHCU_HTTPS_HOST%"${KITCHCU_HTTPS_HOST##*[![:space:]]}"}"
  log "kitchCU HTTPS for: ${hosts}"
  local internal
  internal=$(http_addrs "${ip}, ${HOST_KITCHCU:-10.20.0.11}, kitchcu.internal")
  cat > /opt/ckac/infra/gcp-vm/Caddyfile <<EOF
{
	email ${CADDY_EMAIL:-admin@kitchcu.com}
}

${hosts} {
	@portal host kitchcu.com www.kitchcu.com
	handle @portal {
		reverse_proxy portal-web:80
	}

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
		respond "Unknown host" 404
	}
}

${internal} {
	reverse_proxy gateway:8000
}
EOF
}

deploy_kitchcu() {
  local env=/opt/ckac/infra/gcp-vm/.env
  if [ "$MODE" = "https" ]; then
    log "HTTPS only. Containers are not rebuilt."
    if [ ! -f "$env" ]; then
      log "No existing install. Run: vm-deploy-all.sh kitchcu"
      return 1
    fi
  else
    ensure_swap 2048
    update_repo /opt/ckac https://github.com/sinhakgaurav/kitchcu.git || return 1
    copy_env_once /opt/ckac/infra/gcp-vm/.env /opt/ckac/infra/gcp-vm/.env.production.example || return 1
  fi
  set_kv "$env" WESENSEU_API_URL "${WESENSEU_API_URL:-}"
  set_kv "$env" WESENSEU_API_KEY "${KITCHCU_API_KEY:-}"
  set_kv "$env" GOOGLE_MAPS_API_KEY "${GOOGLE_MAPS_API_KEY:-}"
  # The app seeder signs in with OTP 123456. That code is accepted only when
  # APP_ENV is development or test. Production refuses it unless WhatsApp is configured.
  if [ -z "${WHATSAPP_ACCESS_TOKEN:-}" ]; then
    set_kv "$env" APP_ENV "development"
    log "WhatsApp OTP is not configured. APP_ENV=development so the app seeder can sign in with demo OTP 123456."
  fi
  publish_env "$env" /opt/ckac/.env || return 1
  local ip
  ip=$(public_ip)
  write_kitchcu_caddy "$ip" || return 1
  if [ "$MODE" = "https" ]; then
    docker compose -p gcp-vm -f /opt/ckac/infra/gcp-vm/docker-compose.prod.yml \
      --env-file /opt/ckac/infra/gcp-vm/.env up -d --no-build --force-recreate caddy || return 1
  else
    bash /opt/ckac/infra/gcp-vm/update-prod.sh --already-updated || return 1
    if [ -z "${WHATSAPP_ACCESS_TOKEN:-}" ]; then
      docker compose -p gcp-vm -f /opt/ckac/infra/gcp-vm/docker-compose.prod.yml \
        --env-file "$env" up -d --no-build --force-recreate identity || return 1
    fi
  fi
  if [ -n "${KITCHCU_HTTPS_HOST:-}" ]; then
    if ! wait_https "$KITCHCU_HTTPS_HOST"; then
      if [ "${PIPELINE:-0}" = "1" ]; then
        log "HTTPS for ${KITCHCU_HTTPS_HOST} is not ready yet. HTTP stays up and setup continues."
        PIPE_HTTPS="pending"
      else
        return 1
      fi
    fi
  fi
  wait_port80 || return 1
}

migrate_role() {
  local n=0 svc
  case "$ROLE" in
    wesenseu)
      out=$(docker compose -p wesenseu --project-directory /opt/wesenseu exec -T backend python -m alembic upgrade head 2>&1)
      rc=$?
      printf '%s\n' "$out" >&2
      if [ "$rc" -eq 0 ]; then
        return 0
      fi
      if printf '%s\n' "$out" | grep -q "No module named alembic"; then
        log "The gateway image has no alembic. Tables are created when the API starts, so seed continues."
        return 0
      fi
      return 1
      ;;
    monitour)
      docker compose --project-directory /opt/monitour \
        -f /opt/monitour/docker-compose.platform.yml \
        -f /opt/monitour/docker-compose.monitour-only.yml \
        --env-file /opt/monitour/.env.platform \
        exec -T backend alembic upgrade head
      ;;
    kitchcu)
      while [ "$n" -lt 30 ]; do
        if curl -sf --max-time 8 http://127.0.0.1:18000/health/ready | grep -q '"identity"[[:space:]]*:[[:space:]]*true'; then
          return 0
        fi
        n=$((n + 1))
        sleep 6
      done
      log "kitchCU migrations have not reported identity=true yet"
      return 1
      ;;
    enterweu)
      for svc in auth_service user_service interview_service subscription_service consultancy_service admin_service content_service notification_service; do
        n=0
        while [ "$n" -lt 8 ]; do
          if docker compose -p enterweu --project-directory /opt/enterweu \
            --env-file /opt/enterweu/.env.prod \
            -f /opt/enterweu/docker-compose.yml \
            -f /opt/enterweu/docker-compose.prod.yml \
            -f /tmp/enterweu-host-ports.yml \
            exec -T "$svc" python manage.py migrate --noinput; then
            break
          fi
          n=$((n + 1))
          log "migrate $svc retry $n"
          sleep 8
        done
        [ "$n" -lt 8 ] || return 1
      done
      ;;
    *)
      return 1
      ;;
  esac
}

seed_and_test() {
  local script
  script="$(cd "$(dirname "$0")" && pwd)/vm-test-seed.sh"
  if [ ! -f "$script" ]; then
    script=/tmp/vm-test-seed.sh
  fi
  if [ ! -f "$script" ]; then
    log "vm-test-seed.sh is not on this VM"
    return 1
  fi
  bash "$script" "$ROLE" both
}

run_deploy() {
  if [ -z "${ROLE:-}" ]; then
    echo "Usage: vm-deploy-all.sh kitchcu|enterweu|monitour|wesenseu [full|https|pipeline]" >&2
    exit 2
  fi
  case "$MODE" in
    full|https|pipeline) ;;
    *)
      echo "Usage: vm-deploy-all.sh kitchcu|enterweu|monitour|wesenseu [full|https|pipeline]" >&2
      exit 2
      ;;
  esac

  PIPELINE=0
  PIPE_HTTPS="ok"
  if [ "$MODE" = "pipeline" ]; then
    PIPELINE=1
  fi

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
  local setup="fail" migrate="skipped" seed="skipped" test="skipped" priv
  if [ "$rc" -eq 0 ]; then
    setup="ok"
  fi
  if [ "$PIPELINE" = "1" ] && [ "$rc" -eq 0 ]; then
    if migrate_role; then
      migrate="ok"
    else
      migrate="fail"
    fi
    if [ "$migrate" = "ok" ]; then
      if seed_and_test; then
        seed="ok"
        test="ok"
      else
        seed="fail"
        test="fail"
      fi
    fi
  fi
  priv=$(curl -sf -H "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip || true)
  final=0
  if [ "$setup" != "ok" ] || [ "$migrate" = "fail" ] || [ "$seed" = "fail" ]; then
    final=1
  fi
  log "finished exit=$final external_ip=${ip:-unknown}"
  echo "RESULT role=$ROLE setup=$setup migrate=$migrate https=${PIPE_HTTPS} seed=$seed test=$test public=${ip:-unknown} private=${priv:-unknown}"
  exit "$final"
}

if [ "${VM_DEPLOY_SOURCE_ONLY:-0}" != "1" ]; then
  run_deploy
fi
