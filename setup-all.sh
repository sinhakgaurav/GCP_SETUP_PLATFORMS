#!/usr/bin/env bash
# Cloud Shell entry point. One VM per app.
# Order on each VM: install, migrate, Caddy/HTTPS, the app's own seeder, health test.
# Existing Docker installs are left in place. Volumes are not wiped.
#
#   export GITHUB_TOKEN=...    # repo scope; the script never prints it
#   bash setup-all.sh
#   bash setup-all.sh wesenseu https
#   bash setup-all.sh monitour pipeline
set -u

PROJECT="${PROJECT:-narad-wesenseu}"
ZONE="${ZONE:-asia-south1-a}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
ONLY_ROLE="${1:-}"
ONLY_MODE="${2:-pipeline}"
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

echo "Project $PROJECT zone $ZONE"
echo "Private network: wesenseu 10.20.0.10, kitchcu 10.20.0.11, enterweu 10.20.0.12, monitour 10.20.0.13"
results=""
ran=0
for item in "${VMS[@]}"; do
  vm="${item%% *}"
  role="${item##* }"
  if [ -n "$ONLY_ROLE" ] && [ "$role" != "$ONLY_ROLE" ]; then
    continue
  fi
  ran=1
  echo ""
  echo "===== $role ($vm) ====="
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
exit "$failed"
