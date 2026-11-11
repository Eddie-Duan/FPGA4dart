# Restore VMnet adapter static IPs and restart VMware network services.
# MUST run elevated. ASCII log to .vm-ip-pin\fixip.log
$ErrorActionPreference = 'Continue'

$dir = 'C:\Users\DUANboyang\Desktop\FPGA4dart\.vm-ip-pin'
$log = Join-Path $dir 'fixip.log'
$pairs = @(
    @{ Name = 'VMware Network Adapter VMnet1'; Ip = '192.168.187.1' },
    @{ Name = 'VMware Network Adapter VMnet8'; Ip = '192.168.189.1' }
)
$svcDhcp = 'VMnetDHCP'
$svcNat = 'VMware NAT Service'

if (Test-Path $log) { Remove-Item $log -Force }
function L([string]$m) { Add-Content -Path $log -Value ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding ASCII }

L '=== restore adapter IPs ==='
$pr = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
L ('elevated=' + $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))

foreach ($p in $pairs) {
    $r = & netsh interface ip set address name="$($p.Name)" static $($p.Ip) 255.255.255.0 2>&1 | Out-String
    L ('set ' + $p.Name + ' -> ' + $p.Ip + ' : ' + ($r -replace "`r?`n", ' ').Trim())
}
Start-Sleep -Seconds 2

foreach ($p in $pairs) {
    $ip = @(Get-NetIPAddress -InterfaceAlias $p.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { $_.IPAddress })
    L ('check ' + $p.Name + ' ipv4=' + ($(if ($ip.Count) { $ip -join ',' } else { 'NONE' })))
}

# ---- restart services so DHCP binds to the restored addresses ----
Stop-Service $svcDhcp -Force -ErrorAction SilentlyContinue
Stop-Service $svcNat  -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Start-Service $svcNat  -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1
Start-Service $svcDhcp -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3
L ('services: dhcp=' + (Get-Service $svcDhcp -EA SilentlyContinue).Status + ' nat=' + (Get-Service $svcNat -EA SilentlyContinue).Status)

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
        $mt = $null; $i = 240
        while ($i -lt ($n - 1)) { $c = $buf[$i]; if ($c -eq 255) { break }; if ($c -eq 0) { $i++; continue }; $ln = $buf[$i + 1]; if ($c -eq 53) { $mt = $buf[$i + 2] }; $i = $i + 2 + $ln }
        L ('  probe[' + $tag + ']: REPLY type=' + $mt + ' yiaddr=' + $yi)
        return $yi
    } catch { L ('  probe[' + $tag + ']: ' + $_.Exception.Message); return $null }
    finally { if ($sock) { $sock.Dispose() } }
}

$null = Probe-Dhcp 'aa:bb:cc:00:11:22' 'random'
$null = Probe-Dhcp '00:0c:29:51:6e:83' 'pinned'

$lz = 'C:\ProgramData\VMware\vmnetdhcp.leases'
L ('leases mtime=' + (Get-Item $lz).LastWriteTime + ' lines=' + @(Get-Content $lz).Count)
L '=== done ==='
exit 0
