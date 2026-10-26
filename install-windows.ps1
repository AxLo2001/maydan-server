# Maydan Al Hayy: one-command server install / update for Windows Server 2016-2022.
# Run in PowerShell as Administrator:
#   Set-ExecutionPolicy Bypass -Scope Process -Force; [Net.ServicePointManager]::SecurityProtocol = 'Tls12'; iex ((New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/AxLo2001/maydan-server/main/install-windows.ps1'))
# Running it again updates the server and keeps all data and secrets.
# It does not touch other programs: the API listens on 127.0.0.1:3100, and only ports 80/443 are opened for HTTPS.

& {
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

$Root    = 'C:\maydan'
$App     = Join-Path $Root 'app'
$EnvFile = Join-Path $Root 'maydan.env'
$Logs    = Join-Path $Root 'logs'
$Bin     = Join-Path $Root 'bin'
$Backups = Join-Path $Root 'backups'
$ApiPort = 3100
$RepoZip = 'https://github.com/AxLo2001/maydan-server/archive/refs/heads/main.zip'

function Step([string]$t) { Write-Host ''; Write-Host "==> $t" -ForegroundColor Green }
function Info([string]$t) { Write-Host "    $t" }
function Warn([string]$t) { Write-Host "!!  $t" -ForegroundColor Yellow }
function Fail([string]$t) { Write-Host "xx  $t" -ForegroundColor Red; throw $t }
function NewSecret([int]$bytes) {
  $b = New-Object byte[] $bytes
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
  return (($b | ForEach-Object { $_.ToString('x2') }) -join '')
}
function ReadEnv {
  $h = @{}
  foreach ($line in Get-Content $EnvFile) { if ($line -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*$') { $h[$Matches[1]] = $Matches[2] } }
  return $h
}
function RunNative([string]$exe, [string[]]$argv) {
  # native tools write notices to stderr; do not let PowerShell treat that as an error
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  & $exe @argv | Out-Host
  $code = $LASTEXITCODE; $ErrorActionPreference = $old
  if ($code -ne 0) { Fail "$([IO.Path]::GetFileName($exe)) failed (exit $code)" }
}

$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Fail 'Open PowerShell as Administrator and run the command again.' }

Step '1/8 Checking Node.js'
$node = (Get-Command node.exe -ErrorAction SilentlyContinue).Source
if (-not $node) { Fail 'Node.js is not installed. Install Node.js 20 or newer from nodejs.org, then run this again.' }
$nodeMajor = [int]((& $node -v).TrimStart('v').Split('.')[0])
if ($nodeMajor -lt 20) { Fail "Node.js $nodeMajor is too old. Install Node.js 20 or newer." }
$npm = Join-Path (Split-Path $node) 'npm.cmd'
Info "node $(& $node -v)"

Step '2/8 Folders and secrets'
foreach ($d in @($Root, $Logs, $Bin, $Backups)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
& icacls.exe $Root /inheritance:r /grant:r 'Administrators:(OI)(CI)F' 'SYSTEM:(OI)(CI)F' | Out-Null
if (-not (Test-Path $EnvFile)) {
  $ip = $null
  foreach ($u in @('https://api.ipify.org', 'https://ifconfig.me/ip')) { try { $ip = (Invoke-RestMethod -Uri $u -TimeoutSec 10).ToString().Trim(); break } catch {} }
  if (-not ($ip -match '^\d+\.\d+\.\d+\.\d+$')) { Fail 'Could not find the public IP address of this server.' }
  $dbPass = NewSecret 24
  $lines = @(
    "DATABASE_URL=postgresql://maydan:$dbPass@127.0.0.1:5432/maydan",
    "JWT_SECRET=$(NewSecret 48)",
    "PORT=$ApiPort",
    "HOST=$($ip.Replace('.', '-')).sslip.io",
    "DBPASS=$dbPass",
    "PGSUPER=$(NewSecret 24)"
  )
  Set-Content -Path $EnvFile -Value $lines -Encoding ASCII
  Info "secrets saved in $EnvFile (Administrators only)"
}
$E = ReadEnv

Step '3/8 Downloading the server code'
$tmpZip = Join-Path $env:TEMP 'maydan-server.zip'
$tmpDir = Join-Path $env:TEMP 'maydan-server-src'
Invoke-WebRequest -Uri $RepoZip -OutFile $tmpZip -UseBasicParsing
if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force }
Expand-Archive -Path $tmpZip -DestinationPath $tmpDir -Force
Stop-ScheduledTask -TaskName 'MaydanAPI' -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object { $_.CommandLine -like '*C:\maydan\app\server.js*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 1
if (Test-Path $App) { Remove-Item $App -Recurse -Force }
Move-Item -Path (Join-Path $tmpDir 'maydan-server-main') -Destination $App
Push-Location $App
RunNative $npm @('install', '--omit=dev', '--no-audit', '--no-fund', '--loglevel=error')
Pop-Location

Step '4/8 PostgreSQL database'
$psql = Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\psql.exe' -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
if (-not $psql) {
  Info 'downloading PostgreSQL 16 from EnterpriseDB (about 350 MB)...'
  $pgExe = Join-Path $env:TEMP 'postgresql-16-windows-x64.exe'
  $got = $false
  foreach ($v in @('16.15-5', '16.15-4', '16.15-3', '16.15-2', '16.15-1', '16.14-1', '16.13-1', '16.12-1')) {
    try {
      Invoke-WebRequest -Uri "https://get.enterprisedb.com/postgresql/postgresql-$v-windows-x64.exe" -OutFile $pgExe -UseBasicParsing
      if ((Get-Item $pgExe).Length -gt 100MB) { Info "got PostgreSQL $v"; $got = $true; break }
    } catch { }
  }
  if (-not $got) { Fail 'Could not download PostgreSQL. Check the internet connection of the server and run again.' }
  Info 'installing PostgreSQL (5 to 10 minutes, no output while it works)...'
  $pgArgs = @('--mode', 'unattended', '--unattendedmodeui', 'none', '--superpassword', $E.PGSUPER, '--serverport', '5432', '--enable-components', 'server,commandlinetools')
  $proc = Start-Process -FilePath $pgExe -ArgumentList $pgArgs -Wait -PassThru
  if ($proc.ExitCode -ne 0) { Fail "PostgreSQL installer failed (exit $($proc.ExitCode)). Send this to Claude." }
  Remove-Item $pgExe -Force -ErrorAction SilentlyContinue
  $psql = Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\psql.exe' -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
  if (-not $psql) { Fail 'PostgreSQL did not install. Send the messages above to Claude.' }
}
$psql = $psql.FullName
$pgBin = Split-Path $psql
Get-Service -Name 'postgresql*' -ErrorAction SilentlyContinue | Where-Object Status -ne 'Running' | Start-Service
$env:PGPASSWORD = $E.PGSUPER
$env:PGOPTIONS = '-c client_min_messages=warning'
$base = @('-h', '127.0.0.1', '-p', '5432', '-U', 'postgres', '-v', 'ON_ERROR_STOP=1', '-q', '-X')
$ok = $false
for ($i = 0; $i -lt 20; $i++) {
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  & $psql @base -tAc 'select 1' 2>$null | Out-Null; $code = $LASTEXITCODE
  $ErrorActionPreference = $old
  if ($code -eq 0) { $ok = $true; break }
  Start-Sleep -Seconds 3
}
if (-not $ok) { Fail 'Cannot sign in to PostgreSQL. If PostgreSQL was installed before this script, tell Claude.' }

$roles = @'
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'maydan') then create role maydan login; end if;
end $$;
grant authenticated to maydan;
'@
$rolesFile = Join-Path $env:TEMP 'maydan-roles.sql'
Set-Content -Path $rolesFile -Value $roles -Encoding UTF8
RunNative $psql ($base + @('-f', $rolesFile))
RunNative $psql ($base + @('-c', "alter role maydan password '$($E.DBPASS)'"))
$old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
$hasDb = (& $psql @base -tAc "select 1 from pg_database where datname = 'maydan'") 2>$null
$ErrorActionPreference = $old
if ("$hasDb".Trim() -ne '1') { RunNative $psql ($base + @('-c', 'create database maydan')) }
foreach ($f in @('01-auth.sql', '02-schema.sql', '03-grants.sql', '04-social.sql', '05-challenges.sql')) { RunNative $psql ($base + @('-d', 'maydan', '-f', (Join-Path $App "sql\$f"))) }
RunNative $psql ($base + @('-d', 'maydan', '-c', 'grant usage on schema auth to maydan; grant execute on function auth.sign_up(text,text,text), auth.sign_in(text,text) to maydan; grant select, insert, delete on auth.refresh_tokens to maydan; grant select on auth.users to maydan;'))
Remove-Item Env:\PGPASSWORD, Env:\PGOPTIONS -ErrorAction SilentlyContinue

Step '5/8 Caddy (automatic HTTPS)'
$caddy = Join-Path $Bin 'caddy.exe'
if (-not (Test-Path $caddy)) { Invoke-WebRequest -Uri 'https://caddyserver.com/api/download?os=windows&arch=amd64' -OutFile $caddy -UseBasicParsing }
$caddyfile = @"
{
	storage file_system C:/maydan/caddy-data
}
$($E.HOST) {
	encode gzip
	reverse_proxy 127.0.0.1:$ApiPort
	header -Server
}
"@
Set-Content -Path (Join-Path $Root 'Caddyfile') -Value $caddyfile -Encoding ASCII
foreach ($p in @(80, 443)) {
  $used = Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction SilentlyContinue | Where-Object { (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName -ne 'caddy' }
  if ($used) { Warn "Port $p is used by $((Get-Process -Id $used[0].OwningProcess).ProcessName). HTTPS needs it free. Tell Claude." }
}

Step '6/8 Starting the server (runs at every boot)'
Set-Content -Path (Join-Path $Root 'start-api.cmd') -Encoding ASCII -Value @(
  '@echo off', "cd /d $App", "`"$node`" `"$App\server.js`" >> `"$Logs\api.log`" 2>&1")
Set-Content -Path (Join-Path $Root 'start-caddy.cmd') -Encoding ASCII -Value @(
  '@echo off', "cd /d $Root", "`"$caddy`" run --config `"$Root\Caddyfile`" --adapter caddyfile >> `"$Logs\caddy.log`" 2>&1")
function Register-Always([string]$name, [string]$cmdFile) {
  $a = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/c `"$cmdFile`""
  $t = New-ScheduledTaskTrigger -AtStartup
  $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
  $p = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
  Register-ScheduledTask -TaskName $name -Action $a -Trigger $t -Settings $s -Principal $p | Out-Null
  Start-ScheduledTask -TaskName $name
}
Stop-ScheduledTask -TaskName 'MaydanCaddy' -ErrorAction SilentlyContinue
Get-Process caddy -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $caddy } | Stop-Process -Force -ErrorAction SilentlyContinue
Register-Always 'MaydanAPI' (Join-Path $Root 'start-api.cmd')
Register-Always 'MaydanCaddy' (Join-Path $Root 'start-caddy.cmd')
if (-not (Get-NetFirewallRule -DisplayName 'Maydan HTTPS' -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -DisplayName 'Maydan HTTPS' -Direction Inbound -Protocol TCP -LocalPort 80,443 -Action Allow | Out-Null
}

Step '7/8 Daily backup and password tool'
Set-Content -Path (Join-Path $Root 'backup.ps1') -Encoding ASCII -Value @"
`$e = @{}; foreach (`$l in Get-Content '$EnvFile') { if (`$l -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*$') { `$e[`$Matches[1]] = `$Matches[2] } }
`$env:PGPASSWORD = `$e.PGSUPER
& '$pgBin\pg_dump.exe' -h 127.0.0.1 -U postgres -Fc maydan -f ('$Backups\maydan-' + (Get-Date -Format 'yyyy-MM-dd') + '.dump')
Get-ChildItem '$Backups\*.dump' | Where-Object LastWriteTime -lt (Get-Date).AddDays(-14) | Remove-Item -Force
"@
$ba = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$Root\backup.ps1`""
$bt = New-ScheduledTaskTrigger -Daily -At '03:30'
$bp = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Unregister-ScheduledTask -TaskName 'MaydanBackup' -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName 'MaydanBackup' -Action $ba -Trigger $bt -Principal $bp | Out-Null
Set-Content -Path (Join-Path $Root 'maydan-password.ps1') -Encoding ASCII -Value @"
# usage (as Administrator):  C:\maydan\maydan-password.ps1 user@email.com NewPassword123
param([Parameter(Mandatory=`$true)][string]`$Email, [Parameter(Mandatory=`$true)][string]`$Password)
if (`$Password.Length -lt 8) { Write-Host 'Password must be at least 8 characters'; return }
`$e = @{}; foreach (`$l in Get-Content '$EnvFile') { if (`$l -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*$') { `$e[`$Matches[1]] = `$Matches[2] } }
`$env:PGPASSWORD = `$e.PGSUPER
`$q = "select auth.set_password('" + `$Email.Replace("'", "''") + "', '" + `$Password.Replace("'", "''") + "')"
`$r = & '$psql' -h 127.0.0.1 -U postgres -d maydan -tAc `$q
if ("`$r".Trim() -eq 't') { Write-Host "Password changed for `$Email" } else { Write-Host "No account with email `$Email" }
"@

Step '8/8 Checking'
$healthy = $false
for ($i = 0; $i -lt 20; $i++) {
  try { $r = Invoke-RestMethod -Uri "http://127.0.0.1:$ApiPort/health" -TimeoutSec 3; if ($r.ok) { $healthy = $true; break } } catch {}
  Start-Sleep -Seconds 2
}
if (-not $healthy) {
  Write-Host ''; Get-Content (Join-Path $Logs 'api.log') -Tail 25 -ErrorAction SilentlyContinue
  Fail 'The server did not start. Send the messages above to Claude.'
}
Info 'server is running on 127.0.0.1:3100'
$https = $false
for ($i = 0; $i -lt 30; $i++) {
  try { $r = Invoke-RestMethod -Uri "https://$($E.HOST)/health" -TimeoutSec 5; if ($r.ok) { $https = $true; break } } catch {}
  Start-Sleep -Seconds 3
}
Write-Host ''
Write-Host 'INSTALLED' -ForegroundColor Green
Write-Host 'Server address (send it to Claude):'
Write-Host "    https://$($E.HOST)" -ForegroundColor Green
if (-not $https) {
  Warn 'HTTPS is not answering yet. The certificate can take a few minutes.'
  Warn "If it still fails, make sure ports 80 and 443 are open in your VPS provider's firewall panel."
  Write-Host '    Caddy log:'; Get-Content (Join-Path $Logs 'caddy.log') -Tail 8 -ErrorAction SilentlyContinue
}
}
