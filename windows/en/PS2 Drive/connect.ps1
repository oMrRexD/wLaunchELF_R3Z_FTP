# Mounts the PS2 FTP as Windows drives:
#   P: = SD2PSX card (mmce/0)   M: = memory card in use (mc/0)   H: = HDD exFAT (ata/0)
#
# Two mounts, each in a hidden folder under %LOCALAPPDATA%, and the letters point inside them (subst):
#   PS2-net    -> P: and M:  (everything that goes through the SD2PSX) with ONE connection only. The SD2PSX
#                 cannot handle two operations at the same time: listing a folder in the middle of a write
#                 breaks the write ("Local write failed"). With one connection, the PC does one thing at a time.
#   PS2-net-HD -> H:  also with ONE connection. The HDD could take two, but the PS2 network stack accepts 5
#                 connections in total (control + data) and, with 2 on H:, Explorer opening P: while H: was
#                 computing its free space went past 5 and the PS2 dropped one. With 1 + 1, the worst case is 4.
# The small "PS2 - uploads" window (monitor.ps1) shows what is really being uploaded: Windows says a copy
# is finished as soon as the file reaches the cache on the PC, and the upload to the PS2 only starts after that.
# Needs WinFsp installed and the PS2 with the wLaunchELF FTP open (the FTP server starts by itself).
$here  = Split-Path -Parent $MyInvocation.MyCommand.Path
$rc    = Join-Path $here 'rclone.exe'
$ps2   = '192.168.1.111'
$log   = Join-Path $env:TEMP 'ps2-drive.log'
# Free space: FTP does not report it, and rclone shows 1 PB. Only on H: can it be computed for real: size of the
# exFAT partition (444 GiB here: change it to the size of yours) minus the sum of the files, which rclone redoes by
# scanning the HDD over FTP (~4 s) every --dir-cache-time (hence 5 min on H:). P: and M: are the same mount
# (one connection only for the SD2PSX), so there is no right number for each: they keep the 1 PB, which at least
# never makes Windows refuse a copy for lack of space.
$mounts = @(
    @{ Folder = Join-Path $env:LOCALAPPDATA 'PS2-net';    Remote = '';      Connections = 1; Port = 5572;
       Extras = @('--dir-cache-time', '5s') },
    @{ Folder = Join-Path $env:LOCALAPPDATA 'PS2-net-HD'; Remote = 'ata/0'; Connections = 1; Port = 5574;
       Extras = @('--dir-cache-time', '5m', '--vfs-used-is-size', '--vfs-disk-space-total-size', '444G') }
)
# name of each letter in Explorer. Windows only uses the name from the registry (DriveIcons\<letter>\DefaultLabel)
# when the volume has no name, so the mounts come up with --volname " " (it ends up empty).
$letters = @(
    @{ Letter = 'P:'; Target = Join-Path $mounts[0].Folder 'mmce\0'; Name = 'SD2PSX card';        Label = 'SD2PSX Card' },
    @{ Letter = 'M:'; Target = Join-Path $mounts[0].Folder 'mc\0';   Name = 'memory card in use'; Label = 'PS2 Memory Card' },
    @{ Letter = 'H:'; Target = $mounts[1].Folder;                    Name = 'PS2 HDD (exFAT)';    Label = 'PS2 HDD' }
)
$icons = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\DriveIcons'

# mounted = the folder exists and shows what is on the PS2
function Mounted($m) { [bool](Get-ChildItem -LiteralPath $m.Folder -Force -ErrorAction SilentlyContinue | Select-Object -First 1) }

function Finish($code) { Write-Host ''; Read-Host '  Press Enter to close' | Out-Null; exit $code }

if (-not (Test-Path 'C:\Program Files (x86)\WinFsp\bin\winfsp-x64.dll')) {
    Write-Host ''
    Write-Host '  WinFsp is missing. Install it (https://winfsp.dev/rel/) and run this again.'
    Finish 1
}

Write-Host ''
Write-Host "  Looking for the PS2 at $ps2 ..."
if (-not (Test-NetConnection $ps2 -Port 21 -InformationLevel Quiet -WarningAction SilentlyContinue)) {
    Write-Host ''
    Write-Host '  The PS2 did not answer. On the PS2: open "wLaunchELF FTP"'
    Write-Host '  and wait for the IP to show on screen.'
    Finish 1
}

# The server accepts anonymous login; rclone only requires the "obscured" password (this one is "ps2").
# It stays fixed because it goes into the name of the cache folder: fixed, each mount always uses the same
# folder, and whatever was not uploaded (PS2 turned off too early) goes up by itself on the next connection.
$pw = 'URKHqrTKudapzjgXtN0h1gjuhw'

foreach ($m in $mounts) {
    if (Mounted $m) { continue }
    # leftover of a mount that went down: WinFsp requires that the folder does not exist. Only deleted if empty.
    if (Test-Path $m.Folder) { try { [IO.Directory]::Delete($m.Folder) } catch { } }

    # an idle connection closes after 15 s, so it does not hold a slot on the PS2 for nothing
    $remote = ":ftp,host=$ps2,user=anonymous,pass=$pw,disable_epsv=true,disable_mlsd=true,idle_timeout=15s,concurrency=$($m.Connections):$($m.Remote)"
    $arguments = @(
        'mount', "`"$remote`"", "`"$($m.Folder)`"", '--volname', '" "',
        # 'full' cache: whoever opens the same file at the same time shares a single connection, and only the
        # part that was read stays on the PC (opening an ISO does not download all of it). Past 2 GB, the oldest goes.
        # 5 s before uploading: joins consecutive writes to the same file into a single upload.
        '--vfs-cache-mode', 'full', '--vfs-cache-max-size', '2G', '--vfs-write-back', '5s',
        # one upload at a time
        '--transfers', '1',
        '--attr-timeout', '1s',
        # without this the files show up without execute permission, and Explorer refuses to open .bat/.exe
        # from the drives with "Windows cannot access the specified device..."
        '--file-perms', '0777',
        '--contimeout', '10s', '--timeout', '60s', '--low-level-retries', '3',
        '--rc', '--rc-no-auth', '--rc-addr', "127.0.0.1:$($m.Port)",
        '--no-console', '--log-level', 'NOTICE', '--log-file', "`"$log`"",
        # writes straight to the final name: no .partial file + rename on the card
        '--inplace'
    ) + $m.Extras -join ' '
    Start-Process -FilePath $rc -ArgumentList $arguments -WindowStyle Hidden
}

# waits for both mounts (up to 20 s)
for ($i = 0; $i -lt 40; $i++) {
    if (-not ($mounts | Where-Object { -not (Mounted $_) })) { break }
    Start-Sleep -Milliseconds 500
}

$map = (subst.exe) -join "`n"
$missing = @()
foreach ($l in $letters) {
    if ($map -match [regex]::Escape("$($l.Letter)\: => $($l.Target)")) { Write-Host "  $($l.Letter) was already connected."; continue }
    if (Test-Path "$($l.Letter)\") { Write-Host "  $($l.Letter) is used by something else - skipping the $($l.Name)."; $missing += $l.Letter; continue }
    if (-not (Test-Path $l.Target)) { Write-Host "  The $($l.Name) did not show up on the PS2 FTP - no $($l.Letter)."; $missing += $l.Letter; continue }
    # the name of the letter: only creates/uses the key that is ours (marked with PS2net), never touches a name that already existed
    $key = Join-Path $icons ($l.Letter.TrimEnd(':') + '\DefaultLabel')
    $ours = -not (Test-Path $key) -or ((Get-ItemProperty -Path (Split-Path $key) -ErrorAction SilentlyContinue).PS2net -eq 1)
    if ($ours) {
        New-Item -Path $key -Force | Out-Null
        Set-Item -Path $key -Value $l.Label
        New-ItemProperty -Path (Split-Path $key) -Name 'PS2net' -Value 1 -PropertyType DWord -Force | Out-Null
    }
    subst.exe $l.Letter $l.Target
}
if (-not (Test-Path 'P:\')) {
    Write-Host "  Could not mount P:. Details in: $log"
    Finish 1
}

# the small uploads window (only one)
$monitor = Join-Path $here 'monitor.ps1'
$running = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*monitor.ps1*' }
if (-not $running) {
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$monitor`"" -WindowStyle Hidden
}

Write-Host ''
Write-Host '  Done!  P: = SD2PSX card    M: = memory card in use    H: = PS2 HDD (exFAT)'
if ($missing) { Write-Host "  Missing: $($missing -join ' ')" }
Write-Host '  Windows says a copy is finished before it reaches the PS2: what is really'
Write-Host '  being uploaded shows in the small "PS2 - uploads" window.'
Write-Host '  Before turning the PS2 off or leaving the FTP, run "Disconnect PS2.bat".'
# (it does not open Explorer by itself)
Start-Sleep -Seconds 3
