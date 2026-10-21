# GCP command reference

Project `narad-wesenseu`, zone `asia-south1-a`. Prefix every command with the Python `gcloud.py` path from SKILL.md.

## Inventory

```text
gcloud compute instances list --project=narad-wesenseu
gcloud compute firewall-rules list --project=narad-wesenseu
gcloud services list --enabled --project=narad-wesenseu
```

## One app

Copy `vm-deploy-all.sh` and `vm-test-seed.sh` to the VM, then:

```text
sudo bash /tmp/vm-deploy-all.sh wesenseu pipeline
sudo bash /tmp/vm-deploy-all.sh kitchcu pipeline
sudo bash /tmp/vm-deploy-all.sh enterweu pipeline
sudo bash /tmp/vm-deploy-all.sh monitour pipeline
```

`https` as the second argument refreshes Caddy certificates and does not rebuild images.

Seeders already in the apps, called by `vm-test-seed.sh`:

- WesenseU: `python -m app.db.seed_demo`
- kitchCU: `infra/gcp-vm/bulk-seed.sh`
- EnterWeU: `infra/gcp-vm/seed-demo.sh`
- Monitour: `scripts/seed-all-platform.sh`

## Firewall

Public: `platform-net-http` allows tcp 80 and 443. SSH: `platform-net-ssh` allows tcp 22.
Private: `platform-net-app` allows app ports only from `10.20.0.0/24`.

## CDN

Bucket `wesenseu-invocations`, address and backend `wesenseu-files`, host `files.wesenseu.com`. The bucket is private. Do not print the signing key. `files.wesenseu.com` points at the CDN address, not the WesenseU VM.
