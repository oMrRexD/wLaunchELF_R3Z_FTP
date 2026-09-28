# Unmounts P:, M: and H: only after whatever was written to them has finished uploading to the PS2.
# If the PS2 is already off, or the upload makes no progress for 2 minutes, it stops waiting: what is
# missing stays in the cache on the PC and goes up by itself the next time you connect.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$rc   = Join-Path $here 'rclone.exe'
$ps2  = '192.168.1.111'
$base = Join-Path $env:LOCALAPPDATA 'PS2-net'   # PS2-net and PS2-net-HD

function Ps2Online { Test-NetConnection $ps2 -Port 21 -InformationLevel Quiet -WarningAction SilentlyContinue }
function Rc($port, $command) {
    try { Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$port/$command" -Body '{}' -ContentType 'application/json' -TimeoutSec 10 }
    catch { $null }
}

# 5572 = SD2PSX (P: and M:), 5574 = HDD (H:); 5573 was M: in an older version (one mount per letter)
$ports = 5572, 5573, 5574
$processes = @{}
foreach ($port in $ports) {
    $p = Get-CimInstance Win32_Process -Filter "Name='rclone.exe'" |
        Where-Object { $_.CommandLine -match "mount .*127\.0\.0\.1:$port" }
    if ($p) { $processes[$port] = $p }
}

# 1) waits for the uploads
foreach ($port in $processes.Keys) {
    if (-not (Rc $port 'core/version')) { continue }   # hung: it is just ended, further down
    $lastProgress = [DateTime]::Now; $lastBytes = -1; $warned = $false
    while ($true) {
        $st = Rc $port 'core/stats'
        $bytes = [long]($st.bytes)
        if ($bytes -ne $lastBytes) { $lastBytes = $bytes; $lastProgress = [DateTime]::Now }
        $vfs = Rc $port 'vfs/stats'
        if (-not $vfs) {
            # rc is slow to answer in the middle of an upload; only give up if the mount is gone or stopped moving
            if (-not (Get-Process -Id $processes[$port].ProcessId -ErrorAction SilentlyContinue)) { break }
            if (([DateTime]::Now - $lastProgress).TotalSeconds -gt 120) { break }
            $e = @($st.transferring | Where-Object { $_ -and "$($_.srcFs)" -notlike ':ftp*' }) | Select-Object -First 1
            if ($e) { Write-Host ('    {0}: {1}%' -f (Split-Path $e.name -Leaf), $e.percentage) }
            Start-Sleep -Seconds 2; continue
        }
        $left = [int]$vfs.diskCache.uploadsInProgress + [int]$vfs.diskCache.uploadsQueued
        if ($left -eq 0) { break }
        if (-not $warned) { Write-Host '  Finishing the pending uploads...'; $warned = $true }
        $uploads = @($st.transferring | Where-Object { $_ -and "$($_.srcFs)" -notlike ':ftp*' })
        if ($uploads) {
            $e = $uploads[0]
            Write-Host ('    {0} file(s) left - {1}: {2}%' -f $left, (Split-Path $e.name -Leaf), $e.percentage)
        } else {
            Write-Host "    $left file(s) left"
        }
        if (-not (Ps2Online)) {
            Write-Host "    The PS2 does not answer. $left file(s) stay on the PC and go up"
            Write-Host '    by themselves the next time you connect.'
            break
        }
        if (([DateTime]::Now - $lastProgress).TotalSeconds -gt 120) {
            Write-Host "    The upload has not moved for 2 minutes ($($st.lastError))."
            Write-Host "    $left file(s) stay on the PC and go up the next time you connect."
            break
        }
        Start-Sleep -Seconds 3
    }
}

# 2) removes the letters that point to the PS2 mounts
foreach ($line in (subst.exe)) {
    if ($line -like "*=> $base*") { subst.exe $line.Substring(0, 2) /d }
}
# and the names Connect gave them (only the ones marked as ours), so another disk that one day gets
# the same letter is not labeled
foreach ($letter in 'P', 'M', 'H') {
    $key = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\DriveIcons\$letter"
    if ((Get-ItemProperty -Path $key -ErrorAction SilentlyContinue).PS2net -ne 1) { continue }
    Remove-Item -Path "$key\DefaultLabel" -Recurse -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $key -Name 'PS2net' -ErrorAction SilentlyContinue
    if (-not (Get-ChildItem $key -ErrorAction SilentlyContinue) -and -not ((Get-Item $key).Property)) {
        Remove-Item -Path $key -ErrorAction SilentlyContinue
    }
}

# 3) closes the mounts; one that is hung, or did not exit, is ended
foreach ($port in $processes.Keys) {
    Rc $port 'core/quit' | Out-Null
    $processes[$port] | ForEach-Object { Wait-Process -Id $_.ProcessId -Timeout 15 -ErrorAction SilentlyContinue }
    $processes[$port] | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host '  Done: PS2 drives disconnected. You can leave the FTP on the PS2 now.'
Start-Sleep -Seconds 3
