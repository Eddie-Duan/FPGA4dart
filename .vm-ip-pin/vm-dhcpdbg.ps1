# Run VMnetDHCP.exe in foreground to capture why it does not serve.
# MUST run elevated. ASCII log to .vm-ip-pin\dhcpdbg.log
$ErrorActionPreference = 'Continue'

$dir = 'C:\Users\DUANboyang\Desktop\FPGA4dart\.vm-ip-pin'
$log = Join-Path $dir 'dhcpdbg.log'
$exe = 'D:\VMWorkstationPro\VMnetDHCP.exe'
$outF = Join-Path $dir 'dhcp-console.out'
$errF = Join-Path $dir 'dhcp-console.err'
$svc = 'VMnetDHCP'

if (Test-Path $log) { Remove-Item $log -Force }
Remove-Item $outF, $errF -ErrorAction SilentlyContinue
function L([string]$m) { Add-Content -Path $log -Value ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding ASCII }

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

L '=== dhcp debug run ==='
$pr = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
L ('elevated=' + $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))

Stop-Service $svc -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
L ('service stopped: ' + (Get-Service $svc -EA SilentlyContinue).Status)

L ('starting ' + $exe + ' -d (foreground)')
$child = $null
try {
    $child = Start-Process -FilePath $exe -ArgumentList '-d' -RedirectStandardOutput $outF -RedirectStandardError $errF -PassThru -WindowStyle Hidden -ErrorAction Stop
    L ('child pid=' + $child.Id)
} catch { L ('fork failed: ' + $_.Exception.Message) }

Start-Sleep -Seconds 6
if ($child) {
    $alive = -not $child.HasExited
    L ('child alive after 6s=' + $alive + ' exitcode=' + $(if ($child.HasExited) { $child.ExitCode } else { 'n/a' }))
}

L '--- probes against foreground dhcpd ---'
$null = Probe-Dhcp 'aa:bb:cc:00:11:22' 'random'
$null = Probe-Dhcp '00:0c:29:51:6e:83' 'pinned'

if ($child -and -not $child.HasExited) { try { Stop-Process -Id $child.Id -Force -ErrorAction Stop; L 'child killed' } catch { L ('kill failed: ' + $_.Exception.Message) } }
Start-Sleep -Seconds 1

L '--- stdout ---'
if (Test-Path $outF) { Get-Content $outF -ErrorAction SilentlyContinue | Select-Object -First 40 | ForEach-Object { L ('  o| ' + $_) } } else { L '  (none)' }
L '--- stderr ---'
if (Test-Path $errF) { Get-Content $errF -ErrorAction SilentlyContinue | Select-Object -First 40 | ForEach-Object { L ('  e| ' + $_) } } else { L '  (none)' }

Start-Service $svc -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
L ('service restarted: ' + (Get-Service $svc -EA SilentlyContinue).Status)
$lz = 'C:\ProgramData\VMware\vmnetdhcp.leases'
L ('leases mtime=' + (Get-Item $lz).LastWriteTime)
L '=== dhcp debug done ==='
exit 0
