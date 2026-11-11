# Diagnose + restore VMnetDHCP after the static-reservation change.
# Runs 3 controlled variants and leaves the service in the best known-good state.
# MUST run elevated. Logs ASCII to .vm-ip-pin\diag.log
$ErrorActionPreference = 'Continue'

$dir   = 'C:\Users\DUANboyang\Desktop\FPGA4dart\.vm-ip-pin'
$log   = Join-Path $dir 'diag.log'
$vmdir = 'C:\ProgramData\VMware'
$conf  = Join-Path $vmdir 'vmnetdhcp.conf'
$lease = Join-Path $vmdir 'vmnetdhcp.leases'
$svc   = 'VMnetDHCP'
$mac   = '00:0c:29:51:6e:83'
$ip    = '192.168.189.130'

$origConf  = Join-Path $vmdir 'vmnetdhcp.conf.bak-20261111-212510'
$origLease = Join-Path $vmdir 'vmnetdhcp.leases.bak-20261111-212510'

if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
if (Test-Path $log) { Remove-Item $log -Force }

function L([string]$m) { Add-Content -Path $log -Value ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding ASCII }

function Probe {
    $st = (Get-Service $svc).Status
    $svcPid = $null
    $q = & sc.exe queryex $svc 2>&1 | Out-String
    if ($q -match 'PID\s+:\s+(\d+)') { $svcPid = [int]$Matches[1] }
    $alive = $false
    if ($svcPid) { $alive = (@(Get-Process -Id $svcPid -ErrorAction SilentlyContinue)).Count -gt 0 }
    $u = @([System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveUdpListeners() | Where-Object { $_.Port -eq 67 })
    [pscustomobject]@{ Status = [string]$st; SvcPid = $svcPid; Alive = $alive; Udp67 = $u.Count }
}

function ForceStop {
    $st = (Get-Service $svc).Status
    if ($st -eq 'Stopped') { L '  already stopped'; return }
    try { Stop-Service $svc -Force -ErrorAction Stop } catch { L ('  Stop-Service: ' + $_.Exception.Message) }
    for ($i = 0; $i -lt 20; $i++) {
        if ((Get-Service $svc).Status -eq 'Stopped') { break }
        Start-Sleep -Milliseconds 500
    }
    $st2 = (Get-Service $svc).Status
    L ('  after stop attempt: ' + $st2)
    if ($st2 -ne 'Stopped') {
        $q = & sc.exe queryex $svc 2>&1 | Out-String
        L ('  queryex: ' + (($q -replace "`r?`n", ' ').Trim()))
        L '  trying sc.exe stop'
        & sc.exe stop $svc | Out-Null
        Start-Sleep -Seconds 2
        L ('  after sc stop: ' + (Get-Service $svc).Status)
    }
}

function TryStart([string]$tag) {
    try { Start-Service $svc -ErrorAction Stop } catch { L ('  Start-Service: ' + $_.Exception.Message) }
    Start-Sleep -Seconds 1
    $ok = $false
    for ($i = 0; $i -lt 6; $i++) {
        $p = Probe
        L ('  probe+' + ($i + 1) + 's: status=' + $p.Status + ' svcpid=' + $p.SvcPid + ' alive=' + $p.Alive + ' udp67=' + $p.Udp67)
        if ($p.Status -eq 'Running' -and $p.Alive -and $p.Udp67 -gt 0) { $ok = $true; break }
        Start-Sleep -Seconds 1
    }
    L ('  RESULT ' + $tag + ': ' + $(if ($ok) { 'OK (serving)' } else { 'FAIL (not serving)' }))
    return $ok
}

function WritePinnedConf {
    $c = Get-Content -LiteralPath $origConf -Raw
    if ($c -notmatch '(?im)^\s*host\s+petalinux\b') {
        $nl = "`r`n"
        if (-not $c.EndsWith("`n")) { $c = $c + $nl }
        $c = $c + $nl +
            '# --- pin petalinux dev VM to fixed NAT address ---' + $nl +
            'host petalinux {' + $nl +
            '    hardware ethernet ' + $mac + ';' + $nl +
            '    fixed-address ' + $ip + ';' + $nl +
            '}' + $nl
    }
    Set-Content -LiteralPath $conf -Value $c -Encoding ASCII -NoNewline
}

function WriteCleanLeases {
    $raw = @(Get-Content -LiteralPath $origLease)
    $hdr = @()
    foreach ($l in $raw) { if ($l -match '^\s*#') { $hdr = $hdr + $l } else { break } }
    Set-Content -LiteralPath $lease -Value $hdr -Encoding ASCII
}

L '=== diag start ==='
$pr = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
L ('elevated=' + $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
L ('origConf exists=' + (Test-Path $origConf) + ' origLease exists=' + (Test-Path $origLease))

$init = Probe
L ('initial: status=' + $init.Status + ' svcpid=' + $init.SvcPid + ' alive=' + $init.Alive + ' udp67=' + $init.Udp67)

$results = @()

# ---- Variant A: fully original config + original leases ----
L ''
L '### A: original conf + original leases'
ForceStop
Copy-Item -LiteralPath $origConf  -Destination $conf  -Force
Copy-Item -LiteralPath $origLease -Destination $lease -Force
L '  files restored from backup'
$results += [pscustomobject]@{ Variant = 'A origin+origin'; Ok = (TryStart 'A') }

# ---- Variant B: pinned conf + original leases ----
L ''
L '### B: pinned conf + original leases'
ForceStop
WritePinnedConf
Copy-Item -LiteralPath $origLease -Destination $lease -Force
L '  conf pinned, leases original'
$results += [pscustomobject]@{ Variant = 'B pinned+origin'; Ok = (TryStart 'B') }

# ---- Variant C: pinned conf + clean leases (target) ----
L ''
L '### C: pinned conf + clean leases (target state)'
ForceStop
WriteCleanLeases
L '  conf pinned, leases header-only'
$results += [pscustomobject]@{ Variant = 'C pinned+clean'; Ok = (TryStart 'C') }

# ---- If target failed, fall back to the best known-good ----
$cOk = ($results | Where-Object { $_.Variant -eq 'C pinned+clean' }).Ok
$aOk = ($results | Where-Object { $_.Variant -eq 'A origin+origin' }).Ok

if (-not $cOk) {
    L ''
    L '### C failed -> restoring known-good original files'
    ForceStop
    Copy-Item -LiteralPath $origConf  -Destination $conf  -Force
    Copy-Item -LiteralPath $origLease -Destination $lease -Force
    $null = TryStart 'FALLBACK-origin'
}

L ''
L '=== summary ==='
foreach ($r in $results) { L ('  ' + $r.Variant + ' => ' + $(if ($r.Ok) { 'OK' } else { 'FAIL' })) }
$fin = Probe
L ('final: status=' + $fin.Status + ' svcpid=' + $fin.SvcPid + ' alive=' + $fin.Alive + ' udp67=' + $fin.Udp67)
L ('final conf has host petalinux: ' + ((Get-Content -LiteralPath $conf -Raw) -match '(?im)^\s*host\s+petalinux\b'))
L ('final leases lines: ' + @(Get-Content -LiteralPath $lease).Count)
L '=== diag done ==='
exit 0
