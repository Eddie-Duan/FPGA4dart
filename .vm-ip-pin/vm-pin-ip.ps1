# Pin the VMware NAT guest "petalinux" to 192.168.189.130
# MUST run elevated (Administrator). Logs to .vm-ip-pin\run.log (ASCII).
$ErrorActionPreference = 'Stop'

$dir   = 'C:\Users\DUANboyang\Desktop\FPGA4dart\.vm-ip-pin'
$log   = Join-Path $dir 'run.log'
$vmdir = 'C:\ProgramData\VMware'
$conf  = Join-Path $vmdir 'vmnetdhcp.conf'
$lease = Join-Path $vmdir 'vmnetdhcp.leases'
$svc   = 'VMnetDHCP'
$mac   = '00:0c:29:51:6e:83'
$ip    = '192.168.189.130'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
if (Test-Path $log) { Remove-Item $log -Force }

function L([string]$m) {
    $line = ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m)
    Add-Content -Path $log -Value $line -Encoding ASCII
}
function Fatal([string]$m) { L ('FATAL: ' + $m); L '=== ABORTED ==='; exit 1 }

L ('start; script=' + $PSCommandPath)

try {
    $pr = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $elev = $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    L ('elevated=' + $elev)
    if (-not $elev) { Fatal 'not elevated' }

    # ---- guard: no VM may be running ----
    $vms = @(Get-Process -Name 'vmware-vmx' -ErrorAction SilentlyContinue)
    if ($vms.Count -gt 0) { Fatal ('vmware-vmx.exe is running (' + $vms.Count + '); power off all VMs first') }
    L 'guard ok: no vmware-vmx.exe running'

    # ---- backups ----
    Copy-Item -LiteralPath $conf  -Destination ($conf  + '.bak-' + $stamp) -Force
    Copy-Item -LiteralPath $lease -Destination ($lease + '.bak-' + $stamp) -Force
    L ('backup ok -> *.bak-' + $stamp)

    # ---- 1. static host reservation (idempotent) ----
    $c = Get-Content -LiteralPath $conf -Raw
    if ($c -match '(?im)^\s*host\s+petalinux\b') {
        L 'conf: host petalinux already declared, skip insert'
    } else {
        $nl = "`r`n"
        if (-not $c.EndsWith("`n")) { $c = $c + $nl }
        $block = $nl +
            '# --- pin petalinux dev VM to fixed NAT address (added ' + $stamp + ') ---' + $nl +
            'host petalinux {' + $nl +
            '    hardware ethernet ' + $mac + ';' + $nl +
            '    fixed-address ' + $ip + ';' + $nl +
            '}' + $nl
        Set-Content -LiteralPath $conf -Value ($c + $block) -Encoding ASCII -NoNewline
        L ('conf: appended host petalinux -> ' + $ip)
    }
    $c2 = Get-Content -LiteralPath $conf -Raw
    if ($c2 -notmatch '(?im)^\s*host\s+petalinux\b') { Fatal 'conf write verification failed' }
    if ($c2 -notmatch [regex]::Escape($ip)) { Fatal 'conf does not contain target ip' }
    L 'conf: verified on disk'

    # ---- 2. capture header of leases db ----
    $raw = @(Get-Content -LiteralPath $lease)
    $hdr = @()
    foreach ($l in $raw) { if ($l -match '^\s*#') { $hdr = $hdr + $l } else { break } }
    L ('leases: ' + $raw.Count + ' lines now, header=' + $hdr.Count + ' lines')

    # ---- 3. restart service with a clean leases db ----
    L ('stopping ' + $svc)
    Stop-Service -Name $svc -Force
    $t = 0
    while ((Get-Service $svc).Status -ne 'Stopped' -and $t -lt 40) { Start-Sleep -Milliseconds 500; $t++ }
    L ('service status after stop: ' + (Get-Service $svc).Status)

    Set-Content -LiteralPath $lease -Value $hdr -Encoding ASCII
    L 'leases: rewritten, header only (stale + abandoned records dropped)'

    try { & netsh interface ip delete arpcache 2>&1 | Out-Null; L 'arp cache cleared' }
    catch { L ('arp clear skipped: ' + $_.Exception.Message) }

    L ('starting ' + $svc)
    Start-Service -Name $svc
    Start-Sleep -Seconds 3
    $st = (Get-Service $svc).Status
    L ('service status after start: ' + $st)
    if ($st -ne 'Running') {
        $ev = @(Get-WinEvent -LogName Application -MaxEvents 30 -ErrorAction SilentlyContinue |
                Where-Object { $_.Message -match 'vmnetdhcp|VMware DHCP' })
        foreach ($e in $ev) { L ('EVENT: ' + $e.TimeCreated + ' | ' + $e.Message) }
        Fatal 'VMnetDHCP failed to start - config syntax problem?'
    }

    # ---- 4. verify ----
    $udp = @(Get-NetUDPEndpoint -LocalPort 67 -ErrorAction SilentlyContinue)
    L ('udp/67 listeners: ' + $udp.Count)
    $lines = @(Get-Content -LiteralPath $lease)
    L ('leases file lines after restart: ' + $lines.Count)
    $svcd = Get-Service $svc
    L ('final: ' + $svcd.Name + '=' + $svcd.Status + ' startType=' + $svcd.StartType)
    L '=== DONE OK ==='
    exit 0
}
catch {
    L ('FATAL: ' + $_.Exception.Message)
    exit 1
}
