#!/usr/bin/env bash
# Local checks for Caddy host selection and the EnterWeU small-VM overlay.
# Does not talk to GCP.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

cat > "$TMP/dig" <<'EOF'
#!/usr/bin/env bash
host=""
for arg in "$@"; do
  case "$arg" in
    @*|+*|A) ;;
    *) host="$arg" ;;
  esac
done
case "$host" in
  good.example|www.good.example) printf '%s\n' 10.1.1.1 ;;
  *) printf '%s\n' 9.9.9.9 ;;
esac
EOF
chmod +x "$TMP/dig"

export PATH="$TMP:$PATH"
export VM_DEPLOY_SOURCE_ONLY=1
export CADDY_FILE="$TMP/Caddyfile"
# shellcheck disable=SC1091
source "$ROOT/vm-deploy-all.sh"

got="$(matching_hosts 10.1.1.1 good.example bad.example www.good.example)"
[ "$got" = "good.example, www.good.example" ] || fail "matching_hosts returned [$got]"

addrs="$(http_addrs "10.20.0.11, kitchcu.internal")"
[ "$addrs" = "http://10.20.0.11, http://kitchcu.internal" ] || fail "http_addrs returned [$addrs]"

write_role_caddy "10.1.1.1" "10.20.0.12, enterweu.internal" "127.0.0.1:8081" "127.0.0.1:3000" \
  "good.example, www.good.example" "api.good.example"
grep -q "auto_https off" "$CADDY_FILE" && fail "HTTPS file disabled automatic HTTPS"
grep -q "good.example, www.good.example" "$CADDY_FILE" || fail "web hosts missing"
grep -q "api.good.example" "$CADDY_FILE" || fail "api host missing"
grep -q "http://10.1.1.1" "$CADDY_FILE" || fail "public IP was not kept on HTTP"
grep -q "http://enterweu.internal" "$CADDY_FILE" || fail "internal name was not marked HTTP"
grep -q "bad.example" "$CADDY_FILE" && fail "unmatched host was written into the certificate"

write_role_caddy "10.9.9.9" "10.20.0.10, wesenseu.internal" "127.0.0.1:8011" "127.0.0.1:3001" "" ""
grep -q "auto_https off" "$CADDY_FILE" || fail "empty DNS did not stay on HTTP"
grep -q ":80 {" "$CADDY_FILE" || fail "HTTP catch-all missing"

overlay="$ROOT/enterweu-host-ports.yml"
grep -q 'profiles: \["full"\]' "$overlay" || fail "heavy services are not profile-gated"
grep -q 'command: \["python", "manage.py", "runserver"' "$overlay" || fail "auth still seeds at boot"
grep -q "init_subscription_ledger" "$overlay" || fail "subscription still runs the bulk seeder"
if awk '
  $0 ~ /depends_on/ {on=1; next}
  on && $0 ~ /^  [^ ]/ {on=0}
  on && $0 ~ /elasticsearch|mongodb|kafka|zookeeper/ {found=1}
  END {exit found ? 1 : 0}
' "$overlay"; then
  :
else
  fail "a kept service still depends on elasticsearch, mongo, or kafka"
fi

echo "ok caddy-hosts"
