# GCP setup for the four platforms

One fresh Google Cloud project. kitchCU, EnterWeU, and Monitour each get an e2-small VM. WesenseU gets an e2-medium (4 GB). They share a private network and one private file CDN.

```powershell
.\deploy-all-platforms.ps1 -PrintOnly
.\deploy-all-platforms.ps1
.\deploy-all-platforms.ps1 -Action deploy -Name kitchcu
.\deploy-all-platforms.ps1 -Action update -Name wesenseu
.\deploy-all-platforms.ps1 -Action status
.\test-and-seed.ps1 -Action test
.\test-and-seed.ps1 -Action both -Name wesenseu
.\test-and-seed.ps1 -Local -Action test
```

`deploy` creates a missing VM and installs the app. `update` refreshes an existing VM and refuses to create one. `status` only prints the table. Omit `-Name` to cover all four. Names: `wesenseu`, `kitchcu`, `enterweu`, `monitour`.

Private addresses:

| Project | VM | Address |
|---|---|---|
| wesenseu | wesenseu-medium | 10.20.0.10 |
| kitchcu | kitchcu-small | 10.20.0.11 |
| enterweu | enterweu-small | 10.20.0.12 |
| monitour | monitour-small | 10.20.0.13 |

Partners call WesenseU at `http://10.20.0.10`. EnterWeU callbacks use `http://10.20.0.12`. The public firewall allows 80, 443, and 22. Application ports are open only inside `10.20.0.0/24`. Database ports stay closed.

The script enables Compute, Storage, OS Login, Logging, Monitoring, Certificate Manager, and the Maps APIs used by the apps: Geocoding, Places, Static Maps, and Maps JavaScript. The shared Maps key is printed at the end and written onto kitchCU and Monitour.

The file CDN is the private bucket `gs://wesenseu-invocations` behind `https://files.wesenseu.com`. The signing key is printed once and stored in `keys\`, which is not committed. Platforms download with the signed URL WesenseU returns. They do not put that signing key on their own requests.

`test-and-seed.ps1` checks health and private-network reachability, then loads bulk demo data. It does not wipe databases. kitchCU runs `bulk-seed.sh` with 10 kitchens and 3 months. Monitour runs `seed_all_platform --profile bulk` with `HUGE_DAYS=30`. EnterWeU runs `comprehensive_seeder`. WesenseU runs `seed_demo`. Pass `-Force` to refresh demo rows that are already present. `-Local -Action test` probes the ports on this PC.

Requires the Google Cloud SDK and `gcloud auth login`. Link a billing account before the first deploy. Reruns keep disks, `.env` files, and the CDN key.
