#!/usr/bin/env bash
# Merge /tmp/github_token into /root/platform.env. Does not print the token.
set -euo pipefail
if [ ! -f /tmp/github_token ]; then
  echo "missing /tmp/github_token" >&2
  exit 1
fi
token="$(cat /tmp/github_token)"
touch /root/platform.env
chmod 600 /root/platform.env
grep -v '^GITHUB_TOKEN=' /root/platform.env > /tmp/platform.env.new || true
printf 'GITHUB_TOKEN=%s\n' "$token" >> /tmp/platform.env.new
mv /tmp/platform.env.new /root/platform.env
chmod 600 /root/platform.env
rm -f /tmp/github_token
echo "github token stored"
