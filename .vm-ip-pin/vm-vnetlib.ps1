# Bounce VMware virtual networking through vnetlib (official path) and re-probe.
# MUST run elevated. ASCII log to .vm-ip-pin\vnetlib.log
$ErrorActionPreference = 'Continue'

$dir = 'C:\Users\DUANboyang\Desktop\FPGA4dart\.vm-ip-pin'
$log = Join-Path $dir 'vnetlib.log'
$vnetlib = 'D:\VMWorkstationPro\vnetlib.exe'
$svcDhcp = 'VMnetDHCP'
$svcNat = 'VMware NAT Service'

if (Test-Path $log) { Remove-Item $log -Force }
function L([string]$m) { Add-Content -Path $log -Value ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding ASCII }

function Run-Vnetlib([string[]]$argv, [string]$tag) {
    $out = & $vnetlib @argv 2>&1 | Out-String
    $code = $LASTEXITCODE
    $txt = ($out -replace "`r?`n", ' | ').Trim()
    if ($txt.Length -gt 400) { $txt = $txt.Substring(0, 400) }
    L ('  vnetlib[' + $tag + '] argv=[' + ($argv -join ' ') + '] exit=' + $code + ' out=' + $txt)
    return $code
}

L '=== vnetlib bounce ==='
$pr = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
L ('elevated=' + $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
L ('vnetlib exists=' + (Test-Path $vnetlib))

# learn the CLI surface first
$null = Run-Vnetlib @('--') 'usage1'
$null = Run-Vnetlib @('--', 'help') 'usage2'

# official bounce
$null = Run-Vnetlib @('--', 'stop', 'dhcp') 'stop-dhcp'
Start-Sleep -Seconds 2
$null = Run-Vnetlib @('--', 'stop', 'nat') 'stop-nat'
Start-Sleep -Seconds 2
L ('svc after stops: dhcp=' + (Get-Service $svcDhcp -EA SilentlyContinue).Status + ' nat=' + (Get-Service $svcNat -EA SilentlyContinue).Status)

$null = Run-Vnetlib @('--', 'start', 'nat') 'start-nat'
Start-Sleep -Seconds 2
$null = Run-Vnetlib @('--', 'start', 'dhcp') 'start-dhcp'
Start-Sleep -Seconds 3
L ('svc after starts: dhcp=' + (Get-Service $svcDhcp -EA SilentlyContinue).Status + ' nat=' + (Get-Service $svcNat -EA SilentlyContinue).Status)

foreach ($n in 'VMware Network Adapter VMnet1', 'VMware Network Adapter VMnet8') {
    $ip = @(Get-NetIPAddress -InterfaceAlias $n -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { $_.IPAddress })
    L ('adapter [' + $n + '] ipv4=' + ($(if ($ip.Count) { $ip -join ',' } else { 'NONE' })))
}

function Probe-Dhcp([string]$macStr, [string]$tag) {
    $mac = @()
    foreach ($h in ($macStr -split ':')) { $mac += [byte][Convert]::ToInt32($h, 16) }
    $p = New-Object byte[] 300
    $p[0] = 1; $p[1] = 1; $p[2] = 6; $p[3] = 0
    [Array]::Copy([byte[]](0x11, 0x22, 0x33, 0x44), 0, $p, 4, 4)
    $p[10] = 0x80; $p[11] = 0x00
    [Array]::Copy([byte[]]$mac, 0, $p, 28, 6)
    $p[236] = 99; $p[237] = 130; $p[238] = 83; $p[239] = 99
    $o = 240
    $p[$o] = 53; $o++; $p[$o] = 1; $o++; $p[$o] = 1; $o++
    $p[$o] = 55; $o++; $p[$o] = 3; $o++; $p[$o] = 1; $o++; $p[$o] = 3; $o++; $p[$o] = 6; $o++
    $p[$o] = 255
    $sock = $null
    try {
        $sock = New-Object System.Net.Sockets.Socket([System.Net.Sockets.AddressFamily]::InterNetwork, [System.Net.Sockets.SocketType]::Dgram, [System.Net.Sockets.ProtocolType]::Udp)
        $sock.EnableBroadcast = $true
        $sock.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 68)))
        $sock.ReceiveTimeout = 5000
        $null = $sock.SendTo($p, (New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse('192.168.189.255'), 67)))
        $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $buf = New-Object byte[] 1024
        $n = $sock.ReceiveFrom($buf, [ref]$ep)
        $yi = '{0}.{1}.{2}.{3}' -f $buf[16], $buf[17], $buf[18], $buf[19]
        L ('  probe[' + $tag + ']: yiaddr=' + $yi)
        return $yi
    } catch { L ('  probe[' + $tag + ']: no reply'); return $null }
    finally { if ($sock) { $sock.Dispose() } }
}

$null = Probe-Dhcp 'aa:bb:cc:00:11:22' 'random'
$null = Probe-Dhcp '00:0c:29:51:6e:83' 'pinned'

$lz = 'C:\ProgramData\VMware\vmnetdhcp.leases'
L ('leases mtime=' + (Get-Item $lz).LastWriteTime + ' lines=' + @(Get-Content $lz).Count)
L '=== vnetlib bounce done ==='
exit 0
