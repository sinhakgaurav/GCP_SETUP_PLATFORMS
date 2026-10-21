---
name: gcp-deploy
description: Deploy and operate WesenseU, kitchCU, EnterWeU, and Monitour on Google Cloud with the gcloud CLI. Use when the user mentions GCP, gcloud, Cloud Shell, a VM, HTTPS, Caddy, seeding, or deploying any of the four platforms.
---

# GCP deploy

Manage the live fleet with the Google Cloud CLI. Project `narad-wesenseu`. Zone `asia-south1-a`. Account `naradmuniconnect@gmail.com`.

While doing a task on GCP, you can commit without running test cases. Still commit only when the user asked to commit. Never commit `.env`, `platform.env`, tokens, or signing keys.

## CLI

This PC has the Linux Cloud SDK tarball, not `gcloud.cmd`.

```text
C:\Python313\python.exe "C:\Users\Trouble Zone\Downloads\google-cloud-sdk\google-cloud-sdk\lib\gcloud.py"
```

Pass `--project=narad-wesenseu` on every command. `gcloud compute ssh` and `gcloud compute scp` fail here because the SDK looks for PuTTY. Use Windows OpenSSH.

```text
ssh -i "%USERPROFILE%\.ssh\wesenseu_oslogin" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o BatchMode=yes naradmuniconnect_gmail_com@PUBLIC_IP
```

If the key is rejected, add the public key for 24 hours:

```text
gcloud compute os-login ssh-keys add --project=narad-wesenseu --key-file=%USERPROFILE%\.ssh\wesenseu_oslogin.pub --ttl=24h
```

PowerShell expands `$()` inside double quotes and has no `&&`. Write remote scripts as LF files and copy them. Do not print secrets from `/root/platform.env`.

## Fleet

| Role | VM | Private |
|---|---|---|
| wesenseu | wesenseu-medium | 10.20.0.10 |
| kitchcu | kitchcu-small | 10.20.0.11 |
| enterweu | enterweu-small | 10.20.0.12 |
| monitour | monitour-small | 10.20.0.13 |

Public IPs come from `compute instances list`. Do not trust a cached address. Partners call WesenseU at `http://10.20.0.10`. EnterWeU interview base is `http://10.20.0.10/api/interview/v1`.

## Deploy

Scripts: `E:/projects/GCP_SETUP_PLATFORMS`.

1. `compute instances list` and confirm the VM is RUNNING.
2. Copy `vm-deploy-all.sh` and `vm-test-seed.sh` to `/tmp` with `scp`.
3. Run one role: `sudo bash /tmp/vm-deploy-all.sh ROLE pipeline`.
4. Certificate only, no image rebuild: `sudo bash /tmp/vm-deploy-all.sh ROLE https`.
5. Read the `RESULT` line. Then probe the public health URL.

`pipeline` installs, migrates, starts Caddy, runs that app's own seeder, tests health, and enables the weekly timer for kitchCU, EnterWeU, and Monitour. WesenseU has no weekly timer. Do not pass `--fresh`. Do not start a second seed while one is running.

`bash setup-all.sh recreate` deletes boot disks. Run it only when the user says recreate. It also needs `GITHUB_TOKEN` in the environment and `gcloud compute ssh`, which this PC cannot do. Prefer the OpenSSH path above.

`deploy-all-platforms.ps1` defaults to project id `wesenseu`. Do not run it that way. The live project is `narad-wesenseu`.

## After a change

Report project, public IP, private IP, setup, migrate, HTTPS, seed, test, and weekly. Health checks:

- `https://wesenseu.com/health/live` and `https://api.wesenseu.com/health/live`
- `https://kitchcu.com/` and `https://api.kitchcu.com/health/ready`
- `https://enterweu.com/` and `https://api.enterweu.com/health/`
- `https://monitour.in/` and `https://api.monitour.in/health`

On a 4 GB VM leave EnterWeU Kafka, Elasticsearch, and Mongo off. Leave the WesenseU vision worker, zip analyzer, and Kafka invoke consumer off.

More command detail is in [reference.md](reference.md).
