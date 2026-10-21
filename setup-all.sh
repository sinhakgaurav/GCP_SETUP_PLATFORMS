#!/usr/bin/env bash
# Cloud Shell entry point. One VM per app.
# Order on each VM: install, migrate, Caddy/HTTPS, the app's own seeder, health test.
# Existing Docker installs are left in place. Volumes are not wiped.
#
#   export GITHUB_TOKEN=...    # repo scope; the script never prints it
#   bash setup-all.sh
#   bash setup-all.sh recreate          # delete the four VMs and their boot disks, create e2-medium, then pipeline
#   bash setup-all.sh wesenseu https
#   bash setup-all.sh monitour pipeline
set -u

PROJECT="${PROJECT:-narad-wesenseu}"
ZONE="${ZONE:-asia-south1-a}"
REGION="${ZONE%-*}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
RECREATE=0
if [ "${1:-}" = "recreate" ]; then
  RECREATE=1
  ONLY_ROLE="${2:-}"
  ONLY_MODE="${3:-pipeline}"
else
  ONLY_ROLE="${1:-}"
  ONLY_MODE="${2:-pipeline}"
fi
case "$ONLY_MODE" in
  full|https|pipeline) ;;
  *)
    echo "Usage: setup-all.sh [kitchcu|enterweu|monitour|wesenseu] [full|https|pipeline]" >&2
    exit 2
    ;;
esac

if [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "Export GITHUB_TOKEN in this Cloud Shell first. GitHub rejected anonymous clone." >&2
  exit 1
fi

VMS=(
  "enterweu-small enterweu"
  "monitour-small monitour"
  "wesenseu-medium wesenseu"
  "kitchcu-small kitchcu"
)

stamp_token() {
  local vm="$1"
  local token_file
  umask 077
  token_file="$(mktemp)"
  printf '%s' "$GITHUB_TOKEN" > "$token_file"
  gcloud compute scp "$token_file" "$vm:/tmp/github_token" --project="$PROJECT" --zone="$ZONE"
  gcloud compute scp "$ROOT/stamp-github-token.sh" "$vm:/tmp/stamp-github-token.sh" --project="$PROJECT" --zone="$ZONE"
  rm -f "$token_file"
  gcloud compute ssh "$vm" --project="$PROJECT" --zone="$ZONE" --command="sudo bash /tmp/stamp-github-token.sh"
}

run_vm() {
  local vm="$1" role="$2"
  gcloud compute scp \
    "$ROOT/vm-deploy-all.sh" "$ROOT/vm-test-seed.sh" "$ROOT/enterweu-host-ports.yml" \
    "$vm:/tmp/" --project="$PROJECT" --zone="$ZONE"
  gcloud compute ssh "$vm" --project="$PROJECT" --zone="$ZONE" \
    --command="sudo bash /tmp/vm-deploy-all.sh $role $ONLY_MODE"
}

PLATFORM_APIS="
compute.googleapis.com
storage.googleapis.com
iam.googleapis.com
cloudresourcemanager.googleapis.com
serviceusage.googleapis.com
oslogin.googleapis.com
iap.googleapis.com
logging.googleapis.com
monitoring.googleapis.com
certificatemanager.googleapis.com
apikeys.googleapis.com
geocoding-backend.googleapis.com
places-backend.googleapis.com
static-maps-backend.googleapis.com
maps-backend.googleapis.com
"

print_enabled_services() {
  local enabled api state
  echo ""
  echo "===== Enabled services ====="
  enabled="$(gcloud services list --enabled --project="$PROJECT" --format='value(config.name)' 2>/dev/null || true)"
  for api in $PLATFORM_APIS; do
    state="missing"
    if printf '%s\n' "$enabled" | grep -qx "$api"; then
      state="enabled"
    fi
    printf '%-44s %s\n' "$api" "$state"
  done
}

print_live_sites() {
  local role url code
  echo ""
  echo "===== Live sites ====="
  while read -r role url; do
    [ -n "$role" ] || continue
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$url" 2>/dev/null || true)"
    [ -n "$code" ] || code="err"
    printf '%-12s %-44s %s\n' "$role" "$url" "$code"
    case "$code" in
      2??|3??|4??) ;;
      *) live_bad="${live_bad} ${role}" ;;
    esac
  done <<'EOF'
wesenseu https://wesenseu.com/health/live
wesenseu https://api.wesenseu.com/health/live
kitchcu https://kitchcu.com/
kitchcu https://api.kitchcu.com/health/ready
enterweu https://enterweu.com/
enterweu https://api.enterweu.com/health/
monitour https://monitour.in/
monitour https://api.monitour.in/health
EOF
}

print_cdn() {
  local addr bucket backend keys
  echo ""
  echo "===== CDN ====="
  addr="$(gcloud compute addresses describe wesenseu-files --project="$PROJECT" --global --format='value(address)' 2>/dev/null || true)"
  bucket="$(gcloud storage buckets list --project="$PROJECT" --filter='name=wesenseu-invocations' --format='value(name)' 2>/dev/null || true)"
  backend="$(gcloud compute backend-buckets describe wesenseu-files --project="$PROJECT" --format='value(name)' 2>/dev/null || true)"
  keys="$(gcloud compute backend-buckets describe wesenseu-files --project="$PROJECT" --format='value(cdnPolicy.signedUrlKeyNames)' 2>/dev/null || true)"
  echo "link      https://files.wesenseu.com"
  echo "address   ${addr:-not created}"
  echo "bucket    ${bucket:-not created}"
  echo "backend   ${backend:-not created}"
  echo "key name  wesenseu-files-1"
  if printf '%s\n' "$keys" | grep -q 'wesenseu-files-1'; then
    echo "key       present on the CDN backend"
  else
    echo "key       not attached"
  fi
  echo "access    The bucket is private. WesenseU returns a signed URL. Callers do not put an API key on that URL."
  echo "dns       files.wesenseu.com is an A record for the CDN address above, not the WesenseU VM."
}

collect_failure_logs() {
  local vm="$1"
  echo ""
  echo "===== Failure logs: $vm ====="
  timeout 90 gcloud compute ssh "$vm" --project="$PROJECT" --zone="$ZONE" --command "sudo bash -s" <<'REMOTE' || echo "could not read logs from $vm"
set +e
echo "--- docker ps ---"
docker ps -a --format '{{.Names}} {{.Status}}' | head -40
echo "--- caddy ---"
for name in $(docker ps -a --format '{{.Names}}' | grep -i caddy); do
  echo "--- $name ---"
  docker logs --tail 40 "$name" 2>&1 | tail -40
done
echo "--- exited ---"
docker ps -aq --filter status=exited | head -6 | while read -r id; do
  echo "--- $id ---"
  docker logs --tail 20 "$id" 2>&1 | tail -20
done
REMOTE
}

vm_for_role() {
  case "$1" in
    wesenseu) printf '%s\n' wesenseu-medium ;;
    kitchcu) printf '%s\n' kitchcu-small ;;
    enterweu) printf '%s\n' enterweu-small ;;
    monitour) printf '%s\n' monitour-small ;;
  esac
}

disk_for_role() {
  case "$1" in
    wesenseu|monitour) printf '%s\n' 40GB ;;
    kitchcu|enterweu) printf '%s\n' 50GB ;;
  esac
}

private_for_role() {
  case "$1" in
    wesenseu) printf '%s\n' 10.20.0.10 ;;
    kitchcu) printf '%s\n' 10.20.0.11 ;;
    enterweu) printf '%s\n' 10.20.0.12 ;;
    monitour) printf '%s\n' 10.20.0.13 ;;
  esac
}

save_platform_env() {
  local name="$1" dest="$2"
  gcloud compute ssh "$name" --project="$PROJECT" --zone="$ZONE" --command \
    "sudo cp /root/platform.env /tmp/platform.env.recreate && sudo chmod 644 /tmp/platform.env.recreate" \
    || return 1
  gcloud compute scp "$name:/tmp/platform.env.recreate" "$dest" --project="$PROJECT" --zone="$ZONE" || return 1
  chmod 600 "$dest"
  gcloud compute ssh "$name" --project="$PROJECT" --zone="$ZONE" --command "sudo rm -f /tmp/platform.env.recreate" || true
}

restore_platform_env() {
  local name="$1" src="$2"
  gcloud compute scp "$src" "$name:/tmp/platform.env" --project="$PROJECT" --zone="$ZONE" || return 1
  gcloud compute ssh "$name" --project="$PROJECT" --zone="$ZONE" --command \
    "sudo mv /tmp/platform.env /root/platform.env && sudo chmod 600 /root/platform.env" || return 1
}

wait_vm_ssh() {
  local name="$1" i
  for i in $(seq 1 30); do
    if gcloud compute ssh "$name" --project="$PROJECT" --zone="$ZONE" --command "true" >/dev/null 2>&1; then
      return 0
    fi
    sleep 10
  done
  echo "SSH to $name did not come up" >&2
  return 1
}

recreate_vm() {
  local role="$1"
  local name private disk addr backup scopes
  name="$(vm_for_role "$role")"
  private="$(private_for_role "$role")"
  disk="$(disk_for_role "$role")"
  addr="${name}-ip"
  backup="$(mktemp)"
  chmod 600 "$backup"
  echo ""
  echo "===== recreate $name as e2-medium ====="
  if gcloud compute instances describe "$name" --project="$PROJECT" --zone="$ZONE" --format='value(name)' >/dev/null 2>&1; then
    echo "Saving /root/platform.env before the boot disk is deleted."
    if ! save_platform_env "$name" "$backup"; then
      echo "Refusing to delete $name because platform.env was not saved." >&2
      rm -f "$backup"
      return 1
    fi
    echo "Deleting $name and its boot disk. Static address $addr stays."
    gcloud compute instances delete "$name" --project="$PROJECT" --zone="$ZONE" --quiet --delete-disks=boot || return 1
  fi
  if ! gcloud compute addresses describe "$addr" --project="$PROJECT" --region="$REGION" --format='value(address)' >/dev/null 2>&1; then
    gcloud compute addresses create "$addr" --project="$PROJECT" --region="$REGION" || return 1
  fi
  scopes="https://www.googleapis.com/auth/devstorage.read_write,https://www.googleapis.com/auth/logging.write,https://www.googleapis.com/auth/monitoring.write,https://www.googleapis.com/auth/servicecontrol,https://www.googleapis.com/auth/service.management.readonly,https://www.googleapis.com/auth/trace.append"
  gcloud compute instances create "$name" \
    --project="$PROJECT" --zone="$ZONE" --machine-type=e2-medium \
    --network-interface="network=platform-net,subnet=platform-subnet,private-network-ip=${private},address=${addr}" \
    --image-family=ubuntu-2404-lts-amd64 --image-project=ubuntu-os-cloud \
    --boot-disk-size="$disk" --boot-disk-type=pd-balanced \
    --tags=platform-web --metadata=enable-oslogin=TRUE --scopes="$scopes" || return 1
  wait_vm_ssh "$name" || return 1
  if [ -s "$backup" ]; then
    restore_platform_env "$name" "$backup" || return 1
  fi
  rm -f "$backup"
}

ensure_e2_medium() {
  local vm="$1" current state i
  current="$(gcloud compute instances describe "$vm" --project="$PROJECT" --zone="$ZONE" --format='value(machineType)' 2>/dev/null || true)"
  if [ -z "$current" ]; then
    echo "$vm was not found. This script does not create a new disk."
    return 1
  fi
  case "$current" in
    */e2-medium)
      echo "$vm is already e2-medium"
      return 0
      ;;
  esac
  echo "Stopping $vm to change it to e2-medium. The boot disk stays."
  gcloud compute instances stop "$vm" --project="$PROJECT" --zone="$ZONE" --quiet || return 1
  gcloud compute instances set-machine-type "$vm" --project="$PROJECT" --zone="$ZONE" --machine-type=e2-medium || return 1
  gcloud compute instances start "$vm" --project="$PROJECT" --zone="$ZONE" --quiet || return 1
  for i in $(seq 1 24); do
    state="$(gcloud compute instances describe "$vm" --project="$PROJECT" --zone="$ZONE" --format='value(status)' 2>/dev/null || true)"
    if [ "$state" = "RUNNING" ] && gcloud compute ssh "$vm" --project="$PROJECT" --zone="$ZONE" --command="true" >/dev/null 2>&1; then
      echo "$vm is e2-medium and accepting SSH"
      return 0
    fi
    sleep 5
  done
  echo "$vm did not accept SSH after the resize"
  return 1
}

echo "Project $PROJECT zone $ZONE machine e2-medium"
echo "Private network: wesenseu 10.20.0.10, kitchcu 10.20.0.11, enterweu 10.20.0.12, monitour 10.20.0.13"
if [ "$RECREATE" = "1" ]; then
  echo "Recreate deletes each selected VM and its boot disk, keeps the static public address, then builds an e2-medium."
  for item in "${VMS[@]}"; do
    role="${item##* }"
    if [ -n "$ONLY_ROLE" ] && [ "$role" != "$ONLY_ROLE" ]; then
      continue
    fi
    recreate_vm "$role" || exit 1
  done
fi
results=""
ran=0
ran_roles=""
live_bad=""
for item in "${VMS[@]}"; do
  vm="${item%% *}"
  role="${item##* }"
  if [ -n "$ONLY_ROLE" ] && [ "$role" != "$ONLY_ROLE" ]; then
    continue
  fi
  ran=1
  ran_roles="${ran_roles} ${role}"
  echo ""
  echo "===== $role ($vm) ====="
  if ! ensure_e2_medium "$vm"; then
    line="RESULT role=$role setup=fail migrate=skipped https=skipped seed=skipped test=skipped weekly=skipped public=unknown private=unknown"
    results="${results}${line}"$'\n'
    continue
  fi
  stamp_token "$vm" || true
  output="$(run_vm "$vm" "$role" 2>&1)" || true
  printf '%s\n' "$output"
  line="$(printf '%s\n' "$output" | grep '^RESULT ' | tail -n 1 || true)"
  if [ -z "$line" ]; then
    line="RESULT role=$role setup=fail migrate=skipped https=skipped seed=skipped test=skipped weekly=skipped public=unknown private=unknown"
  fi
  results="${results}${line}"$'\n'
done

if [ -n "$ONLY_ROLE" ] && [ "$ran" -eq 0 ]; then
  echo "Unknown project: $ONLY_ROLE" >&2
  exit 2
fi

echo ""
printf '%-12s %-16s %-16s %-8s %-8s %-8s %-8s %-8s %-8s\n' \
  PROJECT PUBLIC PRIVATE SETUP MIGRATE HTTPS SEED TEST WEEKLY
failed=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  role="$(printf '%s\n' "$line" | sed -n 's/.*role=\([^ ]*\).*/\1/p')"
  public="$(printf '%s\n' "$line" | sed -n 's/.*public=\([^ ]*\).*/\1/p')"
  private="$(printf '%s\n' "$line" | sed -n 's/.*private=\([^ ]*\).*/\1/p')"
  setup="$(printf '%s\n' "$line" | sed -n 's/.*setup=\([^ ]*\).*/\1/p')"
  migrate="$(printf '%s\n' "$line" | sed -n 's/.*migrate=\([^ ]*\).*/\1/p')"
  https="$(printf '%s\n' "$line" | sed -n 's/.*https=\([^ ]*\).*/\1/p')"
  seed="$(printf '%s\n' "$line" | sed -n 's/.*seed=\([^ ]*\).*/\1/p')"
  test="$(printf '%s\n' "$line" | sed -n 's/.*test=\([^ ]*\).*/\1/p')"
  weekly="$(printf '%s\n' "$line" | sed -n 's/.*weekly=\([^ ]*\).*/\1/p')"
  printf '%-12s %-16s %-16s %-8s %-8s %-8s %-8s %-8s %-8s\n' \
    "$role" "$public" "$private" "$setup" "$migrate" "$https" "$seed" "$test" "${weekly:-skipped}"
  if [ "$setup" != "ok" ] || [ "$migrate" = "fail" ] || [ "$seed" = "fail" ] || [ "$test" = "fail" ] || [ "$weekly" = "fail" ]; then
    failed=1
  fi
done <<EOF
$results
EOF

print_enabled_services
print_live_sites
print_cdn

echo ""
echo "===== Failure logs ====="
logged=""
for role in wesenseu kitchcu enterweu monitour; do
  case " ${ran_roles} " in
    *" ${role} "*) ;;
    *) continue ;;
  esac
  need=0
  if printf '%s\n' "$results" | grep -E "role=${role} " | grep -Eq 'setup=fail|migrate=fail|seed=fail|test=fail|weekly=fail'; then
    need=1
  fi
  case " ${live_bad} " in
    *" ${role} "*) need=1 ;;
  esac
  if [ "$need" -eq 1 ]; then
    collect_failure_logs "$(vm_for_role "$role")"
    logged=1
  fi
done
if [ -z "$logged" ]; then
  echo "none"
fi

exit "$failed"
