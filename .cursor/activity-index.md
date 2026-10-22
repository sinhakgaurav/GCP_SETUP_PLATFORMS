# Activity index

Grep this file. Do not load it whole. Detail files live in `.cursor/changes/`.

Format: `YYYY-MM-DD | repo | keywords | outcome | paths | evidence`

2026-10-22 | gcp | post-deploy probes, CASE, RESULT, https | Server probe script prints each case and a RESULT line with cases= | vm-test-seed.sh, tests/test-caddy-hosts.sh | ok caddy-hosts
2026-10-22 | gcp | weekly timer, wesenseu, pipeline | Pipeline enables the WesenseU Friday seed timer with the other roles | vm-deploy-all.sh | enable_weekly_timer wesenseu-weekly-seed.timer
