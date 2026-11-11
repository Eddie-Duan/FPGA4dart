# Apply the static reservation for the petalinux VM, then prove DHCP actually serves
# by sending real DHCPDISCOVER probes on the VMnet8 segment.
# MUST run elevated. ASCII log to .vm-ip-pin\apply.log
$ErrorActionPreference = 'Continue'

$dir   = 'C:\Users\DUANboyang\Desktop\FPGA4dart\.vm-ip-pin'
$log   = Join-Path $dir 'apply.log'
$vmdir = 'C:\ProgramData\VMware'
$conf  = Join-Path $vmdir 'vmnetdhcp.conf'
$lease = Join-Path $vmdir 'vmnetdhcp.leases'
$svc   = 'VMnetDHCP'
$macPin = '00:0c:29:51:6e:83'
$ipPin  = '192.168.189.130'
$origConf  = Join-Path $vmdir 'vmnetdhcp.conf.bak-20261111-212510'
$origLease = Join-Path $vmdir 'vmnetdhcp.leases.bak-20261111-212510'

if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
if (Test-Path $log) { Remove-Item $log -Force }
function L([string]$m) { Add-Content -Path $log -Value ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding ASCII }

function Probe-Dhcp([string]$macStr, [string]$tag) {
    $mac = @()
    foreach ($h in ($macStr -split ':')) { $mac += [byte][Convert]::ToInt32($h, 16) }
    $p = New-Object byte[] 300
    $p[0] = 1; $p[1] = 1; $p[2] = 6; $p[3] = 0
    $xid = [byte[]](0x11, 0x22, 0x33, 0x44)
    [Array]::Copy($xid, 0, $p, 4, 4)
    $p[10] = 0x80; $p[11] = 0x00
    [Array]::Copy([byte[]]$mac, 0, $p, 28, 6)
    $p[236] = 99; $p[237] = 130; $p[238] = 83; $p[239] = 99
    $o = 240
    $p[$o] = 53; $o++; $p[$o] = 1; $o++; $p[$o] = 1; $o++          # DHCPDISCOVER
    $p[$o] = 55; $o++; $p[$o] = 3; $o++; $p[$o] = 1; $o++; $p[$o] = 3; $o++; $p[$o] = 6; $o++
    $p[$o] = 255

    $sock = $null
    try {
        $sock = New-Object System.Net.Sockets.Socket([System.Net.Sockets.AddressFamily]::InterNetwork, [System.Net.Sockets.SocketType]::Dgram, [System.Net.Sockets.ProtocolType]::Udp)
        $sock.EnableBroadcast = $true
        try { $sock.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 68))) }
        catch { L ('  ' + $tag + ': bind 68 failed: ' + $_.Exception.Message); }
        $sock.ReceiveTimeout = 4000
        $dst = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse('192.168.189.255'), 67)
        $null = $sock.SendTo($p, $dst)
        L ('  ' + $tag + ': DISCOVER sent for mac ' + $macStr)

        $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $deadline = (Get-Date).AddSeconds(4)
        while ((Get-Date) -lt $deadline) {
            $buf = New-Object byte[] 1024
            try {
                $n = $sock.ReceiveFrom($buf, [ref]$ep)
            } catch {
                L ('  ' + $tag + ': no reply (' + $_.Exception.Message + ')')
                return $null
            }
            if ($n -lt 240) { continue }
            $yiaddr = '{0}.{1}.{2}.{3}' -f $buf[16], $buf[17], $buf[18], $buf[19]
            $mtype = $null
            $i = 240
            while ($i -lt ($n - 1)) {
                $code = $buf[$i]
                if ($code -eq 255) { break }
                if ($code -eq 0) { $i++; continue }
                $len = $buf[$i + 1]
                if ($code -eq 53 -and $len -ge 1) { $mtype = $buf[$i + 2] }
                $i = $i + 2 + $len
            }
            $mname = switch ($mtype) { 1 { 'DISCOVER' } 2 { 'OFFER' } 3 { 'REQUEST' } 5 { 'ACK' } 6 { 'NAK' } default { 'type' + $mtype } }
            $rchaddr = (($buf[28..33] | ForEach-Object { '{0:x2}' -f $_ }) -join ':')
            L ('  ' + $tag + ': REPLY ' + $mname + ' yiaddr=' + $yiaddr + ' chaddr=' + $rchaddr)
            if ($mtype -eq 2 -or $mtype -eq 5) { return $yiaddr }
        }
        L ('  ' + $tag + ': timeout, no OFFER')
        return $null
    }
    catch { L ('  ' + $tag + ': EXC ' + $_.Exception.Message); return $null }
    finally { if ($sock) { $sock.Dispose() } }
}

L '=== apply start ==='
$pr = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
L ('elevated=' + $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))

# ---- baseline probe BEFORE touching config ----
L ''
L '--- baseline (current conf) ---'
L ('conf has pin: ' + ((Get-Content -LiteralPath $conf -Raw) -match '(?im)^\s*host\s+petalinux\b'))
$base = Probe-Dhcp 'aa:bb:cc:00:11:22' 'baseline'
L ('baseline offer: ' + $(if ($base) { $base } else { 'NONE' }))

# ---- apply target config ----
L ''
L '--- applying pinned conf + clean leases ---'
$c = Get-Content -LiteralPath $origConf -Raw
if ($c -notmatch '(?im)^\s*host\s+petalinux\b') {
    $nl = "`r`n"
    if (-not $c.EndsWith("`n")) { $c = $c + $nl }
    $c = $c + $nl +
        '# --- pin petalinux dev VM to fixed NAT address ---' + $nl +
        'host petalinux {' + $nl +
        '    hardware ethernet ' + $macPin + ';' + $nl +
        '    fixed-address ' + $ipPin + ';' + $nl +
        '}' + $nl
}
Set-Content -LiteralPath $conf -Value $c -Encoding ASCII -NoNewline
L ('conf written; has pin=' + ((Get-Content -LiteralPath $conf -Raw) -match '(?im)^\s*host\s+petalinux\b'))

$raw = @(Get-Content -LiteralPath $origLease)
$hdr = @()
foreach ($l in $raw) { if ($l -match '^\s*#') { $hdr = $hdr + $l } else { break } }

Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
for ($i = 0; $i -lt 20; $i++) { if ((Get-Service $svc).Status -eq 'Stopped') { break }; Start-Sleep -Milliseconds 500 }
L ('service stopped: ' + (Get-Service $svc).Status)
Set-Content -LiteralPath $lease -Value $hdr -Encoding ASCII
L ('leases reset to ' + $hdr.Count + ' header lines')
Start-Service -Name $svc -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
L ('service started: ' + (Get-Service $svc).Status)

# ---- functional probes ----
L ''
L '--- probe 1: random MAC (is DHCP serving at all?) ---'
$r1 = Probe-Dhcp 'aa:bb:cc:00:11:22' 'random'
L ('probe1 offer: ' + $(if ($r1) { $r1 } else { 'NONE' }))

Start-Sleep -Seconds 1
L ''
L '--- probe 2: pinned petalinux MAC (does the reservation bite?) ---'
$r2 = Probe-Dhcp $macPin 'pinned'
L ('probe2 offer: ' + $(if ($r2) { $r2 } else { 'NONE' }))

L ''
L '=== verdict ==='
L ('dhcp serving: ' + $(if ($r1) { 'YES' } else { 'NO' }))
L ('pin honored: ' + $(if ($r2 -eq $ipPin) { 'YES' } elseif ($r2) { 'NO (got ' + $r2 + ')' } else { 'UNKNOWN' }))
L ('leases lines now: ' + @(Get-Content -LiteralPath $lease).Count)
L '=== apply done ==='
exit 0
