#!/usr/bin/env bash
# On one VM: probe health, optionally seed bulk demo data, probe again.
# Does not wipe volumes and does not pass kitchCU --fresh.
# Usage: vm-test-seed.sh wesenseu|kitchcu|enterweu|monitour test|seed|both
set -u

ROLE="${1:-}"
ACTION="${2:-both}"
FORCE="${BULK_FORCE:-0}"

if [ -z "$ROLE" ]; then
  echo "Usage: vm-test-seed.sh ROLE test|seed|both" >&2
  exit 2
fi

log() { echo "[$ROLE] $*"; }

http_ok() {
  local url="$1"
  curl -sf -o /dev/null --max-time 8 "$url"
}

health_of() {
  case "$ROLE" in
    wesenseu)
      http_ok "http://127.0.0.1:8011/health/live" || http_ok "http://10.20.0.10/health/live"
      ;;
    kitchcu)
      curl -sf --max-time 8 "http://127.0.0.1:18000/health/ready" | grep -q '"status"'
      ;;
    enterweu)
      http_ok "http://127.0.0.1:3000/" || http_ok "http://127.0.0.1:8081/"
      ;;
    monitour)
      http_ok "http://127.0.0.1:8000/health/ready" || http_ok "http://127.0.0.1:8000/health" || http_ok "http://127.0.0.1:3000/"
      ;;
    *)
      return 1
      ;;
  esac
}

partner_reach() {
  # Partners must reach WesenseU on the private network. WesenseU checks a partner is up.
  case "$ROLE" in
    wesenseu)
      http_ok "http://10.20.0.12/" || http_ok "http://10.20.0.13/" || http_ok "http://10.20.0.11/"
      ;;
    *)
      http_ok "http://10.20.0.10/health/live" || http_ok "http://10.20.0.10/api/kitchcu/v1/ping"
      ;;
  esac
}

seed_wesenseu() {
  docker compose -p wesenseu --project-directory /opt/wesenseu exec -T \
    -e BULK_FORCE="$FORCE" backend python -m app.db.seed_demo
}

seed_kitchcu() {
  export CKAC_BULK_KITCHENS="${CKAC_BULK_KITCHENS:-10}"
  export CKAC_BULK_MONTHS="${CKAC_BULK_MONTHS:-3}"
  export CKAC_BULK_FULL=1
  bash /opt/ckac/infra/gcp-vm/bulk-seed.sh
  tail -n 20 /var/log/ckac-bulk-seed.log || true
}

seed_enterweu() {
  docker compose -p enterweu --project-directory /opt/enterweu \
    --env-file /opt/enterweu/.env.prod \
    -f /opt/enterweu/docker-compose.yml \
    -f /opt/enterweu/docker-compose.prod.yml \
    exec -T auth_service python manage.py comprehensive_seeder
}

seed_monitour() {
  docker compose --project-directory /opt/monitour \
    -f /opt/monitour/docker-compose.platform.yml \
    -f /opt/monitour/docker-compose.monitour-only.yml \
    --env-file /opt/monitour/.env.platform \
    exec -T -e BULK_FORCE="$FORCE" -e HUGE_DAYS="${HUGE_DAYS:-30}" \
    backend python -m app.db.seed_all_platform --profile bulk
}

HEALTH="fail"
SEED="skipped"
NET="fail"
if health_of; then HEALTH="ok"; fi
if partner_reach; then NET="ok"; else log "private network peer is not reachable yet"; fi

if [ "$ACTION" = "seed" ] || [ "$ACTION" = "both" ]; then
  SEED="fail"
  case "$ROLE" in
    wesenseu) seed_wesenseu && SEED="seeded" ;;
    kitchcu) seed_kitchcu && SEED="seeded" ;;
    enterweu) seed_enterweu && SEED="seeded" ;;
    monitour) seed_monitour && SEED="seeded" ;;
    *) SEED="fail" ;;
  esac
  if health_of; then HEALTH="ok"; fi
fi

log "health=$HEALTH seed=$SEED network=$NET"
echo "RESULT role=$ROLE health=$HEALTH seed=$SEED network=$NET"
if [ "$HEALTH" != "ok" ]; then
  exit 1
fi
if [ "$ACTION" != "test" ] && [ "$SEED" != "seeded" ]; then
  exit 1
fi
exit 0
