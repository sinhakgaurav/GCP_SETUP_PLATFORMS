# Post-deploy probe status

- Why: after a deploy the operator needs each probe, not only health=ok.
- Who: the person deploying WesenseU, kitchCU, EnterWeU, or Monitour.
- Flow: `vm-deploy-all.sh ROLE pipeline` → `vm-test-seed.sh` → `CASE` lines → `STATUS` → `CASES` → `RESULT`.
- Public HTTPS redirect stays in `write_role_caddy` / `write_kitchcu_caddy`. Private `10.20.0.x` stays HTTP.
- Evidence: `bash tests/test-caddy-hosts.sh` → `ok caddy-hosts`. No VM redeploy in this change.
