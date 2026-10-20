#!/usr/bin/env bash
# On one VM: probe health, optionally run that app's own seeder, probe again.
# Does not wipe volumes and does not pass kitchCU --fresh.
# Seed commands are the ones shipped in each repo:
#   wesenseu  python -m app.db.seed_demo
#   kitchcu   infra/gcp-vm/bulk-seed.sh
#   enterweu  infra/gcp-vm/seed-demo.sh
#   monitour  scripts/seed-all-platform.sh
# Usage: vm-test-seed.sh wesenseu|kitchcu|enterweu|monitour test|seed|both
set -u

ROLE="${1:-}"
ACTION="${2:-both}"

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
      code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1:8081/api/auth/login/ || true)
      case "$code" in
        200|400|401|403|404|405) ;;
        *)
          log "auth login returned ${code:-down}"
          return 1
          ;;
      esac
      http_ok "http://127.0.0.1:3000/" || http_ok "http://127.0.0.1/"
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
  if [ -n "${BULK_FORCE:-}" ]; then
    docker compose -p wesenseu --project-directory /opt/wesenseu exec -T \
      -e BULK_FORCE="$BULK_FORCE" backend python -m app.db.seed_demo
  else
    docker compose -p wesenseu --project-directory /opt/wesenseu exec -T \
      backend python -m app.db.seed_demo
  fi
}

seed_kitchcu() {
  bash /opt/ckac/infra/gcp-vm/bulk-seed.sh
  local rc=$?
  tail -n 20 /var/log/ckac-bulk-seed.log >&2 || true
  return "$rc"
}

seed_enterweu() {
  bash /opt/enterweu/infra/gcp-vm/seed-demo.sh
}

seed_monitour() {
  bash /opt/monitour/scripts/seed-all-platform.sh
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
