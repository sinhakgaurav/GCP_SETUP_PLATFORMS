# WesenseU weekly timer

- Why: pipeline left `weekly=skipped` for WesenseU while the other three roles enable Friday 22:00 UTC.
- Flow: `vm-deploy-all.sh` installs `/opt/wesenseu/infra/gcp/wesenseu-weekly-seed.timer` after setup succeeds.
- The unit files live in the WesenseU repo. This script only enables them.
- No disk recreate, no database wipe, no vision worker.
