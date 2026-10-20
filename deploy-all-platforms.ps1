# Fresh GCP project for kitchCU, EnterWeU, Monitour, and WesenseU.
# Keys come from keys.ps1. OpenAI is read from the WesenseU backend .env and is not printed.
#
# Examples:
#   .\deploy-all-platforms.ps1
#   .\deploy-all-platforms.ps1 -Action deploy -Name kitchcu
#   .\deploy-all-platforms.ps1 -Action update -Name wesenseu
#   .\deploy-all-platforms.ps1 -Action status
#   .\deploy-all-platforms.ps1 -PrintOnly

param(
    [string]$Project = "wesenseu",
    [string]$Zone = "asia-south1-a",
    [ValidateSet("deploy", "update", "status")]
    [string]$Action = "deploy",
    [string]$Name = "",
    [string]$Only = "",
    [switch]$PrintOnly
)

$ErrorActionPreference = "Stop"
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$RemoteScript = Join-Path $Here "vm-deploy-all.sh"
$RemotePorts = Join-Path $Here "enterweu-host-ports.yml"
$KeysFile = Join-Path $Here "keys.ps1"
$WesenseuEnv = "E:\projects\WesenseU\backend\.env"
$Region = $Zone.Substring(0, $Zone.LastIndexOf("-"))
$Network = "platform-net"
$Subnet = "platform-subnet"
$CdnBucket = "wesenseu-invocations"
$CdnBackend = "wesenseu-files"
$CdnHost = "files.wesenseu.com"
$CdnKeyName = "wesenseu-files-1"
$CdnKeyFile = Join-Path $Here "keys\cdn-signing-key"
$MapsKeyFile = Join-Path $Here "keys\maps-api-key"

. $KeysFile

$Vms = @(
    @{ Role = "wesenseu"; Name = "wesenseu-medium"; Machine = "e2-medium"; Disk = "40GB"; PrivateIp = "10.20.0.10" },
    @{ Role = "kitchcu"; Name = "kitchcu-small"; Machine = "e2-small"; Disk = "50GB"; PrivateIp = "10.20.0.11" },
    @{ Role = "enterweu"; Name = "enterweu-small"; Machine = "e2-small"; Disk = "50GB"; PrivateIp = "10.20.0.12" },
    @{ Role = "monitour"; Name = "monitour-small"; Machine = "e2-small"; Disk = "40GB"; PrivateIp = "10.20.0.13" }
)

$RoleAlias = @{
    "wesenseu" = "wesenseu"; "wesenseu-medium" = "wesenseu"
    "kitchcu" = "kitchcu"; "kitchcu-small" = "kitchcu"
    "enterweu" = "enterweu"; "enterweu-small" = "enterweu"
    "monitour" = "monitour"; "monitour-small" = "monitour"
}

$Apis = @(
    "compute.googleapis.com",
    "storage.googleapis.com",
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
    "oslogin.googleapis.com",
    "iap.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "certificatemanager.googleapis.com",
    "apikeys.googleapis.com",
    "geocoding-backend.googleapis.com",
    "places-backend.googleapis.com",
    "static-maps-backend.googleapis.com",
    "maps-backend.googleapis.com"
)

$Target = ""
if ($Name) { $Target = $Name.Trim().ToLower() }
elseif ($Only) { $Target = $Only.Trim().ToLower() }
if ($Target -and -not $RoleAlias.ContainsKey($Target)) {
    throw "Unknown project '$Target'. Use wesenseu, kitchcu, enterweu, or monitour."
}
if ($Target) { $Target = $RoleAlias[$Target] }

$script:CdnSigningKey = ""
$script:MapsApiKey = ""
$script:CdnAddress = ""

function Read-EnvValue {
    param([string]$Path, [string]$Key)
    if (-not (Test-Path $Path)) { return "" }
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        if ($line.StartsWith("$Key=")) {
            return $line.Substring($Key.Length + 1).Trim().Trim('"').Trim("'")
        }
    }
    return ""
}

function Ensure-GitKey {
    $dir = Split-Path -Parent $SshKeyPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    if (-not (Test-Path $SshKeyPath)) {
        & ssh-keygen -t ed25519 -f $SshKeyPath -N ([string]::Empty) -q -C "platforms-deploy@wesenseu" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "ssh-keygen failed. Install OpenSSH Client, or set a GitHub token in keys.ps1." }
    }
}

function Invoke-Gcloud {
    param([string[]]$GcloudArgs)
    & gcloud @GcloudArgs
    if ($LASTEXITCODE -ne 0) { throw "gcloud failed." }
}

function Test-GcloudName {
    param([string[]]$GcloudArgs)
    $value = & gcloud @GcloudArgs 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $value) { return $false }
    return $true
}

function Write-Usage {
    Write-Host ""
    Write-Host "Action deploy creates anything missing, then installs the app."
    Write-Host "Action update refreshes one existing app and does not create its VM."
    Write-Host "Action status only prints the table."
    Write-Host "Name: wesenseu | kitchcu | enterweu | monitour. Omit it to cover all four."
    Write-Host ""
    Write-Host "Private network $Network ($Subnet 10.20.0.0/24):"
    foreach ($vm in $Vms) {
        Write-Host ("  {0,-18} {1,-16} {2}" -f $vm.Role, $vm.PrivateIp, $vm.Name)
    }
    Write-Host "Partners call WesenseU at http://10.20.0.10. Callbacks use the private addresses."
    Write-Host "Public firewall: 80, 443, and 22. App ports stay inside 10.20.0.0/24. Databases stay closed."
    Write-Host "Maps APIs: Geocoding, Places, Static Maps, Maps JavaScript."
    Write-Host "CDN: private bucket gs://$CdnBucket at https://$CdnHost"
}

function Get-ResultRows {
    $rows = @()
    $hasGcloud = [bool](Get-Command gcloud -ErrorAction SilentlyContinue)
    foreach ($vm in $Vms) {
        $ip = "-"
        $status = "not running"
        if ($hasGcloud -and -not $PrintOnly) {
            $addr = & gcloud compute addresses describe "$($vm.Name)-ip" --project=$Project --region=$Region --format="value(address)" 2>$null
            if ($LASTEXITCODE -eq 0 -and $addr) { $ip = $addr.Trim() }
            $state = & gcloud compute instances describe $vm.Name --project=$Project --zone=$Zone --format="value(status)" 2>$null
            if ($LASTEXITCODE -eq 0 -and $state -eq "RUNNING") { $status = "running" }
            if ($ip -eq "-" -and $LASTEXITCODE -eq 0) {
                $nat = & gcloud compute instances describe $vm.Name --project=$Project --zone=$Zone --format="value(networkInterfaces[0].accessConfigs[0].natIP)" 2>$null
                if ($LASTEXITCODE -eq 0 -and $nat) { $ip = $nat.Trim() }
            }
        }
        $rows += [pscustomobject]@{ Project = $vm.Role; PublicIp = $ip; Status = $status }
    }
    return $rows
}

function Write-ResultTable {
    param($Rows)
    Write-Host ""
    Write-Host ("{0,-12} {1,-18} {2}" -f "Project", "Public IP", "Status")
    foreach ($row in $Rows) {
        Write-Host ("{0,-12} {1,-18} {2}" -f $row.Project, $row.PublicIp, $row.Status)
    }
}

function Write-SharedKeys {
    Write-Host ""
    Write-Host "Shared CDN (platforms download with the signed URL WesenseU returns):"
    Write-Host "  bucket   gs://$CdnBucket"
    Write-Host "  host     https://$CdnHost"
    if ($script:CdnAddress) { Write-Host "  address  $($script:CdnAddress)" }
    Write-Host "  key name $CdnKeyName"
    if ($script:CdnSigningKey) {
        Write-Host "  CDN key  $($script:CdnSigningKey)"
    }
    elseif (Test-Path $CdnKeyFile) {
        Write-Host "  CDN key  $((Get-Content $CdnKeyFile -Raw).Trim())"
    }
    else {
        Write-Host "  CDN key  (created on deploy or update, saved in keys\cdn-signing-key)"
    }
    Write-Host "Shared Maps key for kitchCU and Monitour:"
    if ($script:MapsApiKey) {
        Write-Host "  Maps key $($script:MapsApiKey)"
    }
    elseif (Test-Path $MapsKeyFile) {
        Write-Host "  Maps key $((Get-Content $MapsKeyFile -Raw).Trim())"
    }
    else {
        Write-Host "  Maps key (created on deploy or update, saved in keys\maps-api-key)"
    }
    Write-Host "Point files.wesenseu.com at the CDN address before signed HTTPS downloads work."
}

function Ensure-GcpProject {
    $id = & gcloud projects describe $Project --format="value(projectId)" 2>$null
    if ($LASTEXITCODE -ne 0) {
        Invoke-Gcloud @("projects", "create", $Project, "--name=$Project")
    }
    Invoke-Gcloud (@("services", "enable", "--project=$Project") + $Apis)
}

function Ensure-Network {
    if (-not (Test-GcloudName @("compute", "networks", "describe", $Network, "--project=$Project", "--format=value(name)"))) {
        Invoke-Gcloud @("compute", "networks", "create", $Network, "--project=$Project", "--subnet-mode=custom")
    }
    if (-not (Test-GcloudName @("compute", "networks", "subnets", "describe", $Subnet, "--project=$Project", "--region=$Region", "--format=value(name)"))) {
        Invoke-Gcloud @("compute", "networks", "subnets", "create", $Subnet, "--project=$Project", "--network=$Network", "--region=$Region", "--range=10.20.0.0/24")
    }
    $rules = @(
        @{ Name = "platform-net-http"; Rules = "tcp:80,tcp:443"; Ranges = "0.0.0.0/0" },
        @{ Name = "platform-net-ssh"; Rules = "tcp:22"; Ranges = "0.0.0.0/0" },
        @{ Name = "platform-net-app"; Rules = "tcp:80,tcp:443,tcp:8000,tcp:8011,tcp:8081,tcp:3000,tcp:3001"; Ranges = "10.20.0.0/24" }
    )
    foreach ($rule in $rules) {
        if (Test-GcloudName @("compute", "firewall-rules", "describe", $rule.Name, "--project=$Project", "--format=value(name)")) { continue }
        Invoke-Gcloud @(
            "compute", "firewall-rules", "create", $rule.Name,
            "--project=$Project", "--network=$Network", "--direction=INGRESS",
            "--action=ALLOW", "--rules=$($rule.Rules)", "--source-ranges=$($rule.Ranges)",
            "--target-tags=platform-web"
        )
    }
}

function New-UrlSafeKey {
    $bytes = New-Object byte[] 16
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return ([Convert]::ToBase64String($bytes).TrimEnd("=").Replace("+", "-").Replace("/", "_"))
}

function Save-SecretFile {
    param([string]$Path, [string]$Value)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $Value, $utf8)
}

function Ensure-Cdn {
    $listed = & gcloud storage buckets list --project=$Project --filter="name=$CdnBucket" --format="value(name)" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $listed) {
        Invoke-Gcloud @("storage", "buckets", "create", "gs://$CdnBucket", "--project=$Project", "--location=$Region", "--uniform-bucket-level-access")
    }
    Invoke-Gcloud @("storage", "buckets", "update", "gs://$CdnBucket", "--public-access-prevention")
    if (-not (Test-GcloudName @("compute", "backend-buckets", "describe", $CdnBackend, "--project=$Project", "--format=value(name)"))) {
        Invoke-Gcloud @(
            "compute", "backend-buckets", "create", $CdnBackend,
            "--project=$Project", "--gcs-bucket-name=$CdnBucket", "--enable-cdn", "--cache-mode=CACHE_ALL_STATIC"
        )
    }
    if (-not (Test-GcloudName @("compute", "addresses", "describe", $CdnBackend, "--project=$Project", "--global", "--format=value(name)"))) {
        Invoke-Gcloud @("compute", "addresses", "create", $CdnBackend, "--project=$Project", "--global")
    }
    if (-not (Test-GcloudName @("compute", "url-maps", "describe", $CdnBackend, "--project=$Project", "--global", "--format=value(name)"))) {
        Invoke-Gcloud @("compute", "url-maps", "create", $CdnBackend, "--project=$Project", "--default-backend-bucket=$CdnBackend", "--global")
    }
    if (-not (Test-GcloudName @("compute", "ssl-certificates", "describe", $CdnBackend, "--project=$Project", "--global", "--format=value(name)"))) {
        Invoke-Gcloud @("compute", "ssl-certificates", "create", $CdnBackend, "--project=$Project", "--domains=$CdnHost", "--global")
    }
    if (-not (Test-GcloudName @("compute", "target-https-proxies", "describe", $CdnBackend, "--project=$Project", "--format=value(name)"))) {
        Invoke-Gcloud @("compute", "target-https-proxies", "create", $CdnBackend, "--project=$Project", "--url-map=$CdnBackend", "--ssl-certificates=$CdnBackend")
    }
    if (-not (Test-GcloudName @("compute", "forwarding-rules", "describe", $CdnBackend, "--project=$Project", "--global", "--format=value(name)"))) {
        Invoke-Gcloud @(
            "compute", "forwarding-rules", "create", $CdnBackend,
            "--project=$Project", "--global", "--target-https-proxies=$CdnBackend",
            "--address=$CdnBackend", "--ports=443"
        )
    }
    $script:CdnAddress = (& gcloud compute addresses describe $CdnBackend --project=$Project --global --format="value(address)" 2>$null)
    if ($script:CdnAddress) { $script:CdnAddress = $script:CdnAddress.Trim() }

    $present = & gcloud compute backend-buckets describe $CdnBackend --project=$Project --format="value(cdnPolicy.signedUrlKeyNames)" 2>$null
    $haveKey = $present -and ($present -match [regex]::Escape($CdnKeyName))
    if (Test-Path $CdnKeyFile) {
        $script:CdnSigningKey = (Get-Content $CdnKeyFile -Raw).Trim()
    }
    if (-not $haveKey) {
        if (-not $script:CdnSigningKey) { $script:CdnSigningKey = New-UrlSafeKey }
        $tmp = Join-Path $env:TEMP ("cdn-key-" + [guid]::NewGuid().ToString("n") + ".txt")
        try {
            Save-SecretFile $tmp $script:CdnSigningKey
            Invoke-Gcloud @("compute", "backend-buckets", "add-signed-url-key", $CdnBackend, "--project=$Project", "--key-name=$CdnKeyName", "--key-file=$tmp")
        }
        finally {
            if (Test-Path $tmp) { Remove-Item -Force $tmp }
        }
    }
    if ($script:CdnSigningKey) { Save-SecretFile $CdnKeyFile $script:CdnSigningKey }
    $number = & gcloud projects describe $Project --format="value(projectNumber)"
    if ($LASTEXITCODE -eq 0 -and $number) {
        $sa = "$($number.Trim())-compute@developer.gserviceaccount.com"
        & gcloud storage buckets add-iam-policy-binding "gs://$CdnBucket" --member="serviceAccount:$sa" --role="roles/storage.objectAdmin" | Out-Null
    }
}

function Ensure-MapsKey {
    if (Test-Path $MapsKeyFile) {
        $script:MapsApiKey = (Get-Content $MapsKeyFile -Raw).Trim()
        if ($script:MapsApiKey) { return }
    }
    $existing = & gcloud services api-keys list --project=$Project --filter="displayName=platforms-maps" --format="value(name)" 2>$null
    $keyName = ""
    if ($LASTEXITCODE -eq 0 -and $existing) { $keyName = ($existing | Select-Object -First 1).ToString().Trim() }
    if (-not $keyName) {
        Invoke-Gcloud @(
            "services", "api-keys", "create", "--project=$Project", "--display-name=platforms-maps",
            "--api-target=service=geocoding-backend.googleapis.com",
            "--api-target=service=places-backend.googleapis.com",
            "--api-target=service=static-maps-backend.googleapis.com",
            "--api-target=service=maps-backend.googleapis.com"
        )
        for ($i = 0; $i -lt 6 -and -not $keyName; $i++) {
            Start-Sleep -Seconds 2
            $existing = & gcloud services api-keys list --project=$Project --filter="displayName=platforms-maps" --format="value(name)" 2>$null
            if ($LASTEXITCODE -eq 0 -and $existing) { $keyName = ($existing | Select-Object -First 1).ToString().Trim() }
        }
    }
    if (-not $keyName) { throw "Maps API key was not created." }
    $secret = & gcloud services api-keys get-key-string $keyName --project=$Project --format="value(keyString)"
    if ($LASTEXITCODE -ne 0 -or -not $secret) { throw "Could not read the Maps API key string." }
    $script:MapsApiKey = $secret.Trim()
    Save-SecretFile $MapsKeyFile $script:MapsApiKey
}

function Wait-VmSsh {
    param([string]$VmName)
    for ($i = 1; $i -le 24; $i++) {
        & gcloud compute ssh $VmName --project=$Project --zone=$Zone --quiet --command="true" 2>$null
        if ($LASTEXITCODE -eq 0) { return }
        Start-Sleep -Seconds 10
    }
    throw "SSH to $VmName did not come up. Check gcloud auth login and OS Login."
}

function Format-EnvLine {
    param([string]$Key, [string]$Value)
    $escaped = $Value.Replace("'", "'\''")
    return "$Key='$escaped'"
}

function Write-RemoteEnv {
    param([string]$Path, [hashtable]$Pairs)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($key in $Pairs.Keys) { $lines.Add((Format-EnvLine $key ([string]$Pairs[$key]))) }
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllLines($Path, $lines, $utf8)
}

function Convert-ToUnixLf {
    param([string]$Path)
    $text = [System.IO.File]::ReadAllText($Path).Replace("`r`n", "`n").Replace("`r", "`n")
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $text, $utf8)
}

function Ensure-Instance {
    param($Vm)
    $addrName = "$($Vm.Name)-ip"
    if (-not (Test-GcloudName @("compute", "addresses", "describe", $addrName, "--project=$Project", "--region=$Region", "--format=value(address)"))) {
        Invoke-Gcloud @("compute", "addresses", "create", $addrName, "--project=$Project", "--region=$Region")
    }
    $state = & gcloud compute instances describe $Vm.Name --project=$Project --zone=$Zone --format="value(status)" 2>$null
    $exists = ($LASTEXITCODE -eq 0)
    if (-not $exists) {
        if ($Action -eq "update") {
            throw "$($Vm.Name) does not exist. Run -Action deploy -Name $($Vm.Role) first."
        }
        $scopes = "https://www.googleapis.com/auth/devstorage.read_write,https://www.googleapis.com/auth/logging.write,https://www.googleapis.com/auth/monitoring.write,https://www.googleapis.com/auth/servicecontrol,https://www.googleapis.com/auth/service.management.readonly,https://www.googleapis.com/auth/trace.append"
        $nic = "network=${Network},subnet=${Subnet},private-network-ip=$($Vm.PrivateIp),address=${addrName}"
        Invoke-Gcloud @(
            "compute", "instances", "create", $Vm.Name,
            "--project=$Project", "--zone=$Zone", "--machine-type=$($Vm.Machine)",
            "--network-interface=$nic",
            "--image-family=ubuntu-2404-lts-amd64", "--image-project=ubuntu-os-cloud",
            "--boot-disk-size=$($Vm.Disk)", "--boot-disk-type=pd-balanced",
            "--tags=platform-web", "--metadata=enable-oslogin=TRUE", "--scopes=$scopes"
        )
    }
    elseif ($state -eq "TERMINATED" -or $state -eq "STOPPED") {
        Invoke-Gcloud @("compute", "instances", "start", $Vm.Name, "--project=$Project", "--zone=$Zone")
    }
}

function Send-And-Run {
    param($Vm, [hashtable]$Pairs)
    $vmName = $Vm.Name
    Convert-ToUnixLf $RemoteScript
    if ($Vm.Role -eq "enterweu") { Convert-ToUnixLf $RemotePorts }
    Wait-VmSsh $vmName
    $tmp = Join-Path $env:TEMP ("platform-" + [guid]::NewGuid().ToString("n") + ".env")
    try {
        Write-RemoteEnv $tmp $Pairs
        Invoke-Gcloud @("compute", "scp", "--project=$Project", "--zone=$Zone", $RemoteScript, "${vmName}:vm-deploy-all.sh")
        Invoke-Gcloud @("compute", "scp", "--project=$Project", "--zone=$Zone", $tmp, "${vmName}:platform.env")
        if ($Vm.Role -eq "enterweu") {
            Invoke-Gcloud @("compute", "scp", "--project=$Project", "--zone=$Zone", $RemotePorts, "${vmName}:enterweu-host-ports.yml")
        }
        if (Test-Path $SshKeyPath) {
            Invoke-Gcloud @("compute", "scp", "--project=$Project", "--zone=$Zone", $SshKeyPath, "${vmName}:id_ed25519")
        }
        $remote = "sudo mkdir -p /root/.ssh /tmp && sudo mv ~/vm-deploy-all.sh /root/vm-deploy-all.sh && sudo mv ~/platform.env /root/platform.env && sudo chmod 755 /root/vm-deploy-all.sh && sudo chmod 600 /root/platform.env"
        if ($Vm.Role -eq "enterweu") { $remote += " && sudo mv ~/enterweu-host-ports.yml /tmp/enterweu-host-ports.yml" }
        $remote += " && if [ -f ~/id_ed25519 ]; then sudo mv ~/id_ed25519 /root/.ssh/id_ed25519 && sudo chmod 600 /root/.ssh/id_ed25519; fi"
        $remote += " && sudo bash /root/vm-deploy-all.sh $($Vm.Role)"
        Invoke-Gcloud @("compute", "ssh", $vmName, "--project=$Project", "--zone=$Zone", "--quiet", "--command=$remote")
    }
    finally {
        if (Test-Path $tmp) { Remove-Item -Force $tmp }
    }
}

Write-Usage

if ($PrintOnly) {
    Write-ResultTable (Get-ResultRows)
    Write-SharedKeys
    exit 0
}

if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) {
    Write-ResultTable (Get-ResultRows)
    Write-SharedKeys
    Write-Host ""
    Write-Host "gcloud is not installed, so nothing was created."
    exit 1
}

if ($Action -eq "status") {
    Write-ResultTable (Get-ResultRows)
    Write-SharedKeys
    exit 0
}

Ensure-GitKey
$openai = Read-EnvValue $WesenseuEnv "OPENAI_API_KEY"
Ensure-GcpProject
Ensure-Network
Ensure-Cdn
Ensure-MapsKey

$failed = @()
foreach ($vm in $Vms) {
    if ($Target -and $vm.Role -ne $Target) { continue }
    $wsu = "http://10.20.0.10"
    $apiUrl = $wsu
    if ($vm.Role -eq "enterweu") { $apiUrl = "$wsu/api/interview/v1" }
    if ($vm.Role -eq "wesenseu") { $apiUrl = "" }
    $pairs = @{
        GITHUB_TOKEN = [string]$GitHubToken
        USE_GIT_SSH = $(if ($UseGitSsh) { "1" } else { "0" })
        KITCHCU_API_KEY = [string]$KitchcuApiKey
        ENTERWEU_API_KEY = [string]$EnterweuApiKey
        MONITOUR_API_KEY = [string]$MonitourApiKey
        KITCHCU_OAUTH_CLIENT_SECRET = [string]$KitchcuOauthSecret
        ENTERWEU_OAUTH_CLIENT_SECRET = [string]$EnterweuOauthSecret
        MONITOUR_OAUTH_CLIENT_SECRET = [string]$MonitourOauthSecret
        WESENSEU_ADMIN_EMAIL = [string]$WesenseuAdminEmail
        WESENSEU_ADMIN_PASSWORD = [string]$WesenseuAdminPassword
        CADDY_EMAIL = [string]$CaddyEmail
        CALLBACK_SECRET = [string]$CallbackSecret
        OPENAI_API_KEY = [string]$openai
        GOOGLE_MAPS_API_KEY = [string]$script:MapsApiKey
        WESENSEU_API_URL = [string]$apiUrl
        ENTERWEU_PUBLIC_BASE = "http://10.20.0.12"
        HOST_WESENSEU = "10.20.0.10"
        HOST_KITCHCU = "10.20.0.11"
        HOST_ENTERWEU = "10.20.0.12"
        HOST_MONITOUR = "10.20.0.13"
        GCS_INVOCATION_BUCKET = [string]$CdnBucket
        INVOCATION_CDN_BASE_URL = "https://$CdnHost"
        INVOCATION_CDN_KEY_NAME = [string]$CdnKeyName
        INVOCATION_CDN_SIGNING_KEY = [string]$script:CdnSigningKey
        INVOCATION_CDN_TTL_SECONDS = "900"
    }
    Write-Host ""
    Write-Host ("----- {0} {1} ({2}) -----" -f $Action, $vm.Role, $vm.PrivateIp)
    try {
        Ensure-Instance $vm
        Send-And-Run $vm $pairs
    }
    catch {
        Write-Host ("{0} failed: {1}" -f $vm.Role, $_.Exception.Message)
        $failed += $vm.Role
    }
}

Write-ResultTable (Get-ResultRows)
Write-SharedKeys
if ($failed.Count -gt 0) {
    Write-Host ""
    Write-Host ("Failed: {0}" -f ($failed -join ", "))
    exit 1
}
exit 0
