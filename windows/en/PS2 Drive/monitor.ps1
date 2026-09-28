# Small "PS2 - uploads" window: shows what is really being uploaded to the PS2.
# Windows says a copy is finished as soon as the file reaches the cache on the PC; the upload to the PS2
# happens afterwards, at the speed of the PS2 network. This window shows up by itself when there is an upload,
# shows file, percentage, speed and time left, and hides when it is done.
# connect.ps1 opens it; it closes by itself when the drives are disconnected.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$ports = 5572, 5574   # SD2PSX (P: and M:) and HDD (H:)

function Rc($port, $command) {
    try { Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$port/$command" -Body '{}' -ContentType 'application/json' -TimeoutSec 2 }
    catch { $null }
}
function FormatSize($b) {
    if ($b -ge 1GB) { '{0:N1} GB' -f ($b / 1GB) } elseif ($b -ge 1MB) { '{0:N1} MB' -f ($b / 1MB) } else { '{0:N0} KB' -f ($b / 1KB) }
}
function Duration($s) {
    if ($null -eq $s -or $s -le 0) { return '?' }
    if ($s -ge 3600) { return '{0} h {1:00} min' -f [math]::Floor($s / 3600), [math]::Floor(($s % 3600) / 60) }
    if ($s -ge 60) { return '{0} min' -f [math]::Ceiling($s / 60) }
    '{0} s' -f [math]::Ceiling($s)
}

$form = New-Object Windows.Forms.Form
$form.Text = 'PS2 - uploads'
$form.Size = New-Object Drawing.Size(600, 200)
$form.FormBorderStyle = 'FixedToolWindow'
$form.StartPosition = 'Manual'
$area = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Location = New-Object Drawing.Point(($area.Right - 610), ($area.Bottom - 210))
$form.ShowInTaskbar = $true
$text = New-Object Windows.Forms.Label
$text.Dock = 'Fill'
$text.Font = New-Object Drawing.Font('Consolas', 10)
$text.Padding = New-Object Windows.Forms.Padding(8)
$form.Controls.Add($text)

$state = @{ Uploading = $false; HasUploaded = $false; IdleSince = [DateTime]::Now; WasMinimized = $false; NoMountTicks = 0; Pending = @{} }

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 2000
$timer.Add_Tick({
    $lines = @(); $pending = 0; $failure = ''
    # a mount exists while there is an rclone running (rc may be slow to answer in the middle of an upload)
    $anyMount = [bool](Get-Process rclone -ErrorAction SilentlyContinue)
    foreach ($port in $ports) {
        $st = Rc $port 'core/stats'
        if (-not $st) { continue }
        # uploads only: the source is the cache on the PC (reads come from the FTP)
        $uploads = @($st.transferring | Where-Object { $_ -and "$($_.srcFs)" -notlike ':ftp*' })
        $vfs = Rc $port 'vfs/stats'
        if ($vfs) {
            $state.Pending[$port] = [int]$vfs.diskCache.uploadsInProgress + [int]$vfs.diskCache.uploadsQueued
        } elseif ($uploads.Count -gt [int]$state.Pending[$port]) {
            $state.Pending[$port] = $uploads.Count   # too busy to answer: at least what is going up
        }
        $pending += [int]$state.Pending[$port]
        foreach ($t in $uploads) {
            $name = Split-Path $t.name -Leaf
            if ($name.Length -gt 34) { $name = $name.Substring(0, 31) + '...' }
            $lines += '  {0}' -f $name
            $lines += '     {0,3}%   {1} of {2}   {3}/s   {4} left' -f $t.percentage, (FormatSize $t.bytes), (FormatSize $t.size), (FormatSize $t.speed), (Duration $t.eta)
        }
        if ($st.lastError -and $pending -gt 0) { $failure = "$($st.lastError)" }
    }

    if (-not $anyMount) {
        # disconnected: closes (waits 3 rounds so it does not close on a blink)
        $state.NoMountTicks++
        if ($state.NoMountTicks -ge 3) { $form.Close() }
        return
    }
    $state.NoMountTicks = 0

    if ($pending -gt 0) {
        $header = @('UPLOADING TO THE PS2 - do NOT close the LaunchELF or turn the PS2 off', '')
        if (-not $lines) { $lines = @('  preparing the upload...') }
        $queued = $pending - [math]::Max(1, $lines.Count / 2)
        if ($queued -gt 0) { $lines += "  and $queued more file(s) in the queue" }
        if ($failure) {
            if ($failure.Length -gt 60) { $failure = $failure.Substring(0, 57) + '...' }
            $lines += "  failed and will try again: $failure"
        }
        $text.Text = ($header + $lines) -join "`r`n"
        $text.ForeColor = [Drawing.Color]::DarkRed
        $form.TopMost = $true
        if ($form.WindowState -eq 'Minimized') { $form.WindowState = 'Normal' }
        $state.Uploading = $true; $state.HasUploaded = $true; $state.WasMinimized = $false
    } else {
        if ($state.Uploading) {
            $state.Uploading = $false; $state.IdleSince = [DateTime]::Now
            [Console]::Beep(880, 150)
        }
        $first = if ($state.HasUploaded) { 'All uploaded. Nothing going up to the PS2 now.' } else { 'Nothing going up to the PS2 now.' }
        $text.Text = "$first`r`n`r`nWhen you copy something to P:, M: or H:, the real upload shows here.`r`nBefore leaving the FTP or turning the PS2 off, run ""Disconnect PS2.bat""."
        $text.ForeColor = [Drawing.Color]::DarkGreen
        $form.TopMost = $false
        # goes away 15 s after becoming idle
        if (-not $state.WasMinimized -and ([DateTime]::Now - $state.IdleSince).TotalSeconds -gt 15) {
            $form.WindowState = 'Minimized'; $state.WasMinimized = $true
        }
    }
})
$timer.Start()
[Windows.Forms.Application]::Run($form)
