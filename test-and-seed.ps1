# Probe each platform and seed bulk demo data. Does not wipe databases.
#
#   .\test-and-seed.ps1
#   .\test-and-seed.ps1 -Action test -Name wesenseu
#   .\test-and-seed.ps1 -Action seed -Name monitour
#   .\test-and-seed.ps1 -Action both -Name kitchcu -Force
#   .\test-and-seed.ps1 -Local -Action test

param(
    [string]$Project = "wesenseu",
    [string]$Zone = "asia-south1-a",
    [ValidateSet("test", "seed", "both")]
    [string]$Action = "both",
    [string]$Name = "",
    [switch]$Force,
    [switch]$Local,
    [switch]$PrintOnly
)

$ErrorActionPreference = "Stop"
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$RemoteScript = Join-Path $Here "vm-test-seed.sh"
$Region = $Zone.Substring(0, $Zone.LastIndexOf("-"))

$Vms = @(
    @{ Role = "wesenseu"; Name = "wesenseu-medium"; LocalUrl = "http://127.0.0.1:8011/health/live" },
    @{ Role = "kitchcu"; Name = "kitchcu-small"; LocalUrl = "http://127.0.0.1:18000/health/ready" },
    @{ Role = "enterweu"; Name = "enterweu-small"; LocalUrl = "http://127.0.0.1:3000/" },
    @{ Role = "monitour"; Name = "monitour-small"; LocalUrl = "http://127.0.0.1:8000/health/ready" }
)

$RoleAlias = @{
    "wesenseu" = "wesenseu"; "wesenseu-medium" = "wesenseu"
    "kitchcu" = "kitchcu"; "kitchcu-small" = "kitchcu"
    "enterweu" = "enterweu"; "enterweu-small" = "enterweu"
    "monitour" = "monitour"; "monitour-small" = "monitour"
}

$Target = ""
if ($Name) { $Target = $Name.Trim().ToLower() }
if ($Target -and -not $RoleAlias.ContainsKey($Target)) {
    throw "Unknown project '$Target'. Use wesenseu, kitchcu, enterweu, or monitour."
}
if ($Target) { $Target = $RoleAlias[$Target] }

function Convert-ToUnixLf {
    param([string]$Path)
    $text = [System.IO.File]::ReadAllText($Path).Replace("`r`n", "`n").Replace("`r", "`n")
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $text, $utf8)
}

function Test-Url {
    param([string]$Url)
    try {
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 8
        return ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500)
    }
    catch {
        return $false
    }
}

function Get-PublicIp {
    param([string]$VmName)
    $addr = & gcloud compute addresses describe "$VmName-ip" --project=$Project --region=$Region --format="value(address)" 2>$null
    if ($LASTEXITCODE -eq 0 -and $addr) { return $addr.Trim() }
    return "-"
}

function Write-Table {
    param($Rows)
    Write-Host ""
    Write-Host ("{0,-12} {1,-18} {2,-8} {3,-10} {4}" -f "Project", "Public IP", "Health", "Seed", "Network")
    foreach ($row in $Rows) {
        Write-Host ("{0,-12} {1,-18} {2,-8} {3,-10} {4}" -f $row.Project, $row.PublicIp, $row.Health, $row.Seed, $row.Network)
    }
}

Write-Host ""
Write-Host "Action $Action. Seed runs the seeder that already ships in each app. It does not wipe databases."
Write-Host "kitchCU: infra/gcp-vm/bulk-seed.sh. EnterWeU: infra/gcp-vm/seed-demo.sh."
Write-Host "Monitour: scripts/seed-all-platform.sh. WesenseU: python -m app.db.seed_demo."
Write-Host "Pass -Force to set BULK_FORCE=1 for the WesenseU and Monitour seeders."

if ($PrintOnly) {
    $blank = foreach ($vm in $Vms) {
        [pscustomobject]@{ Project = $vm.Role; PublicIp = "-"; Health = "-"; Seed = "-"; Network = "-" }
    }
    Write-Table $blank
    exit 0
}

$rows = @()
$failed = @()

if ($Local) {
    foreach ($vm in $Vms) {
        if ($Target -and $vm.Role -ne $Target) { continue }
        $health = "fail"
        if (Test-Url $vm.LocalUrl) { $health = "ok" }
        $seed = "skipped"
        if ($Action -ne "test") { $seed = "remote-only" }
        if ($health -ne "ok") { $failed += $vm.Role }
        $rows += [pscustomobject]@{ Project = $vm.Role; PublicIp = "local"; Health = $health; Seed = $seed; Network = "local" }
    }
    Write-Table $rows
    if ($failed.Count -gt 0) { exit 1 }
    exit 0
}

if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) {
    Write-Host "gcloud is not installed, so the VMs were not tested."
    $blank = foreach ($vm in $Vms) {
        [pscustomobject]@{ Project = $vm.Role; PublicIp = "-"; Health = "fail"; Seed = "skipped"; Network = "-" }
    }
    Write-Table $blank
    exit 1
}

Convert-ToUnixLf $RemoteScript
$forceEnv = ""
if ($Force) { $forceEnv = "BULK_FORCE=1 " }

foreach ($vm in $Vms) {
    if ($Target -and $vm.Role -ne $Target) { continue }
    $ip = Get-PublicIp $vm.Name
    $health = "fail"
    $seed = $(if ($Action -eq "test") { "skipped" } else { "fail" })
    $network = "-"
    Write-Host ""
    Write-Host ("----- {0} {1} -----" -f $Action, $vm.Role)
    & gcloud compute scp --project=$Project --zone=$Zone $RemoteScript "$($vm.Name):vm-test-seed.sh"
    if ($LASTEXITCODE -ne 0) {
        $failed += $vm.Role
        $rows += [pscustomobject]@{ Project = $vm.Role; PublicIp = $ip; Health = $health; Seed = $seed; Network = $network }
        continue
    }
    $remote = "sudo mv ~/vm-test-seed.sh /root/vm-test-seed.sh && sudo chmod 755 /root/vm-test-seed.sh && sudo ${forceEnv}bash /root/vm-test-seed.sh $($vm.Role) $Action"
    $output = & gcloud compute ssh $vm.Name --project=$Project --zone=$Zone --quiet --command=$remote 2>&1 | Out-String
    Write-Host $output
    $match = [regex]::Match($output, "RESULT role=\S+ health=(\S+) seed=(\S+) network=(\S+)")
    if ($match.Success) {
        $health = $match.Groups[1].Value
        $seed = $match.Groups[2].Value
        $network = $match.Groups[3].Value
    }
    if ($health -ne "ok" -or ($Action -ne "test" -and $seed -ne "seeded")) { $failed += $vm.Role }
    $rows += [pscustomobject]@{ Project = $vm.Role; PublicIp = $ip; Health = $health; Seed = $seed; Network = $network }
}

Write-Table $rows
if ($failed.Count -gt 0) { exit 1 }
exit 0
