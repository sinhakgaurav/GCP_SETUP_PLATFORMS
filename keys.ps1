# Keys for the combined deploy. This folder is outside the git repos.
# Product keys match the WesenseU seeder. Paste a GitHub PAT only if a repo is private.
# Leave GitHubToken empty to clone over public HTTPS. The launcher also creates keys\id_ed25519.

$GitHubToken = ""
# Leave this false until the printed public key is a GitHub deploy key. Public HTTPS is the default.
$UseGitSsh = $false
$SshKeyPath = Join-Path $PSScriptRoot "keys\id_ed25519"

$KitchcuApiKey = "wesenseu-api-key-for-kitchcu"
$EnterweuApiKey = "wesenseu-api-key-for-enterweu"
$MonitourApiKey = "wesenseu-api-key-for-monitour"
$KitchcuOauthSecret = "wesenseu-oauth-secret-kitchcu"
$EnterweuOauthSecret = "wesenseu-oauth-secret-enterweu"
$MonitourOauthSecret = "wesenseu-oauth-secret-monitour"

$WesenseuAdminEmail = "admin@wesenseu.local"
$WesenseuAdminPassword = "Admin@2026"
$CaddyEmail = "admin@kitchcu.com"
# Shared HMAC for EnterWeU callbacks. Leave empty until you want signed callbacks.
$CallbackSecret = ""
