# Sends games (ISOs) from the PC to the PS2 HDD, at udpfs speed, without touching the controller.
# Needs the wLaunchELF FTP open on the PS2, sitting on the main menu.
#
# How it works: this script serves the games folder with udpfsd (read only) and, over FTP, leaves a
# job on the PS2 HDD (ata0:/PS2-RECEBER.TXT). The LaunchELF sees the job, switches the network to udpfs (the
# FTP stops), copies each game to ata0:/DVD or ata0:/CD, writes ata0:/PS2-RECEBER.RES and goes back to FTP.
# Here we follow along through the udpfsd log and, when the FTP is back, read the result.
# (The file names and keywords of the job are the protocol the LaunchELF understands: they stay as they are.)
#
# -Simulate: does everything except talking to the PS2 (checks the files, decides CD/DVD, builds the job).
param(
    [switch]$Simulate,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Items
)

$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$base    = Split-Path -Parent $here
$rclone  = Join-Path $base 'PS2 Drive\rclone.exe'
$udpfsd  = Join-Path $base 'udpfsd\udpfsd.exe'
$disconn = Join-Path $base 'PS2 Drive\disconnect.ps1'
$ps2     = '192.168.1.111'
$pw      = 'URKHqrTKudapzjgXtN0h1gjuhw'   # "ps2" obscured for rclone (anonymous login)
# no_check_upload: rclone checks the file after writing it, but the PS2 takes the job and stops the FTP
# within seconds, and the check failed even with the job delivered
$remote  = ":ftp,host=$ps2,user=anonymous,pass=$pw,disable_epsv=true,disable_mlsd=true,no_check_upload=true:"
$job     = 'ata/0/PS2-RECEBER.TXT'
$result  = 'ata/0/PS2-RECEBER.RES'
$mbps    = 2.8   # measured: udpfs from the PC to the HDD

function Finish($code) { Write-Host ''; if (-not $env:PS2_NO_PAUSE) { Read-Host '  Press Enter to close' | Out-Null }; exit $code }
function FormatSize($b) { if ($b -ge 1GB) { '{0:N2} GB' -f ($b / 1GB) } else { '{0:N0} MB' -f ($b / 1MB) } }
function Duration($s) {
    if ($s -ge 3600) { return '{0} h {1:00} min' -f [math]::Floor($s / 3600), [math]::Floor(($s % 3600) / 60) }
    if ($s -ge 60) { return '{0} min' -f [math]::Ceiling($s / 60) }
    return '{0} s' -f [math]::Ceiling($s)
}
function Rc {
    # one FTP connection per command; only touches the HDD (ata), never the SD2PSX card
    $output = & $rclone @args --contimeout 10s --timeout 30s --low-level-retries 2 -q 2>&1
    return @{ Ok = ($LASTEXITCODE -eq 0); Output = $output }
}
function Ps2Online { Test-NetConnection $ps2 -Port 21 -InformationLevel Quiet -WarningAction SilentlyContinue }

# CD or DVD: a PS2 DVD game has UDF (NSR02/NSR03 descriptors right after sector 16); a CD only has ISO9660
function GameType($file) {
    $fs = [IO.File]::OpenRead($file.FullName)
    try {
        $buf = New-Object byte[] 32768
        $fs.Position = 32768
        $n = $fs.Read($buf, 0, $buf.Length)
    } finally { $fs.Close() }
    $txt = [Text.Encoding]::ASCII.GetString($buf, 0, $n)
    if ($txt.Contains('NSR02') -or $txt.Contains('NSR03')) { return 'DVD' }
    if ($file.Length -gt 900MB) { return 'DVD' }
    return 'CD'
}

Write-Host ''
Write-Host ('  SEND GAMES TO PS2 (udpfs)' + $(if ($Simulate) { '  -- SIMULATION, the PS2 is not touched' } else { '' }))
Write-Host ''

# ---- 1. the files ----
$games = @()
foreach ($i in $Items) {
    if (-not $i) { continue }
    if (Test-Path -LiteralPath $i -PathType Container) {
        $games += Get-ChildItem -LiteralPath $i -File | Where-Object { $_.Extension -ieq '.iso' }
    } elseif (Test-Path -LiteralPath $i -PathType Leaf) {
        $games += Get-Item -LiteralPath $i
    } else {
        Write-Host "  Not found: $i"
    }
}
if (-not $games) {
    Write-Host '  Drag the ISOs (or their folder) onto "Send Games to PS2.bat".'
    Finish 1
}

$valid = @()
foreach ($j in $games) {
    $reason = $null
    if ($j.Extension -ine '.iso') { $reason = 'ISO only (.iso)' }
    elseif ($j.Name -notmatch '^[\x20-\x7E]+$') { $reason = 'name with accents or special symbols: rename it with plain letters only' }
    elseif ($j.Name.Length -gt 200) { $reason = 'name too long' }
    elseif ($j.Length -eq 0) { $reason = 'empty file' }
    if ($reason) { Write-Host "  SKIPPING $($j.Name): $reason"; continue }
    $valid += [pscustomobject]@{ File = $j; Folder = (GameType $j); Size = $j.Length }
}
if (-not $valid) { Finish 1 }

# ---- 2. the PS2 HDD: what is already there ----
if ($Simulate) {
    Write-Host '  (simulation: not checking what is already on the PS2 HDD)'
} else {
    Write-Host "  Looking for the PS2 at $ps2 ..."
    if (-not (Ps2Online)) {
        Write-Host '  The PS2 did not answer. Open "wLaunchELF FTP" on the PS2,'
        Write-Host '  wait for the IP to show and leave it on the main menu.'
        Finish 1
    }
    # the P:/M:/H: drives use the FTP, which is going to stop during the copy: disconnect first
    if (Get-CimInstance Win32_Process -Filter "Name='rclone.exe'" | Where-Object { $_.CommandLine -match 'mount ' }) {
        Write-Host '  Disconnecting the P:, M: and H: drives (the PS2 FTP is going to stop during the copy)...'
        & powershell -NoProfile -ExecutionPolicy Bypass -File $disconn | Out-Null
    }
    $existing = @{}
    foreach ($p in 'DVD', 'CD') {
        $r = Rc lsf "${remote}ata/0/$p"
        if ($r.Ok) { foreach ($n in $r.Output) { $existing["$p/$n"] = $true } }
    }
    $r = Rc lsf "${remote}ata/0"
    if (-not $r.Ok) {
        Write-Host '  Could not read the PS2 HDD (ata0:). Is the HDD connected to the PS2?'
        Finish 1
    }
    if ($r.Output -contains 'PS2-RECEBER.TXT') {
        Write-Host '  There is already a job there (from a time that did not finish). Deleting it first.'
        Rc deletefile "${remote}$job" | Out-Null
    }
    if ($r.Output -contains 'PS2-RECEBER.RES') { Rc deletefile "${remote}$result" | Out-Null }
    $toSend = @()
    foreach ($v in $valid) {
        if ($existing["$($v.Folder)/$($v.File.Name)"]) { Write-Host "  ALREADY ON THE HDD, skipping: $($v.Folder)\$($v.File.Name)" }
        else { $toSend += $v }
    }
    $valid = $toSend
    if (-not $valid) { Write-Host '  Nothing new to send.'; Finish 0 }
}

# ---- 3. one send per source folder (udpfsd serves a single folder) ----
$groups = $valid | Group-Object { $_.File.DirectoryName }
$total = ($valid | Measure-Object Size -Sum).Sum
Write-Host ''
foreach ($v in $valid) { Write-Host ('  {0,-4} {1,9}  {2}' -f $v.Folder, (FormatSize $v.Size), $v.File.Name) }
Write-Host ''
Write-Host ("  Total: {0} in {1} game(s). Estimate: ~{2} (at ~{3} MB/s)." -f (FormatSize $total), $valid.Count, (Duration ($total / 1MB / $mbps)), $mbps)
Write-Host ''

$summary = @()
foreach ($g in $groups) {
    $source = $g.Name
    $lines = @('PS2-RECEBER 1') + ($g.Group | ForEach-Object { "$($_.Folder)`t$($_.Size)`t$($_.File.Name)" }) + @('FIM')
    $jobText = ($lines -join "`n") + "`n"
    if ($Simulate) {
        Write-Host "  [simulation] would serve the folder: $source"
        Write-Host '  [simulation] job that would go to the PS2 (ata0:/PS2-RECEBER.TXT):'
        $lines | ForEach-Object { Write-Host "      $($_ -replace "`t", ' | ')" }
        Write-Host ''
        continue
    }

    # ---- 4. udpfs server (read only, no automatic ZSO/CSO decompression) ----
    Get-Process udpfsd -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host '  Closing a udpfs server that was left open from a previous time.'; Stop-Process -Id $_.Id -Force }
    $logErr = Join-Path $env:TEMP 'ps2-send-udpfsd.log'
    $logOut = Join-Path $env:TEMP 'ps2-send-udpfsd.out.log'
    $arg = "-fsroot `"$($source.TrimEnd('\'))`" -ro -no-compression -verbose"
    if ($source.EndsWith('\')) { $arg = "-fsroot `"$source.`" -ro -no-compression -verbose" }
    $srv = Start-Process -FilePath $udpfsd -ArgumentList $arg -WindowStyle Hidden -PassThru `
        -RedirectStandardError $logErr -RedirectStandardOutput $logOut
    Start-Sleep -Seconds 2
    if ($srv.HasExited) { Write-Host "  udpfsd did not start. See $logErr"; Finish 1 }

    # the server is only stopped when it is certain the PS2 is not reading from it (stopping it midway cuts the copy)
    $stopServer = $false
    try {
        # ---- 5. the job ----
        $tmp = Join-Path $env:TEMP 'PS2-RECEBER.TXT'
        [IO.File]::WriteAllText($tmp, $jobText, [Text.Encoding]::ASCII)
        $r = Rc copyto $tmp "${remote}$job" --inplace
        $delivered = $r.Ok
        Write-Host '  Job sent. Waiting for the PS2 to take it (it checks every 3 s, on the main menu)...'

        # taken = the job disappeared from the HDD, or the FTP disappeared (the PS2 already switched the network to udpfs)
        $taken = $false
        for ($t = 0; $t -lt 20 -and -not $taken; $t++) {
            if (-not (Ps2Online)) { $taken = $true; break }
            $r = Rc lsf "${remote}ata/0"
            if ($r.Ok) {
                if ($r.Output -contains 'PS2-RECEBER.TXT') { $delivered = $true }
                elseif ($delivered) { $taken = $true; break }
            }
            Start-Sleep -Seconds 2
        }
        if (-not $taken) {
            Rc deletefile "${remote}$job" | Out-Null
            $stopServer = $true
            Write-Host ''
            if (-not $delivered) {
                Write-Host '  Could not leave the job on the PS2 HDD over FTP.'
            } else {
                Write-Host '  The PS2 did not take the job within 40 s (and I cancelled it). Check:'
                Write-Host '    - whether the LaunchELF on the PS2 is this wLaunchELF FTP (other builds cannot receive);'
                Write-Host '    - whether it is on the main menu (inside the FileBrowser it does not look for jobs).'
            }
            Finish 1
        }
        Write-Host '  The PS2 took the job and is switching the network to udpfs.'
        Write-Host ''

        # ---- 6. following along through the udpfsd log ----
        $sizes = @{}; foreach ($v in $g.Group) { $sizes[$v.File.Name] = $v.Size }
        $groupTotal = ($g.Group | Measure-Object Size -Sum).Sum
        $deadline = [DateTime]::Now.AddSeconds($groupTotal / 1MB / 0.5 + 300)   # very loose: 0.5 MB/s + 5 min
        $current = $null; $readCurrent = 0L; $readTotal = 0L; $pos = 0L
        $samples = New-Object System.Collections.Queue
        $lastRead = [DateTime]::Now; $nextCheck = [DateTime]::Now.AddSeconds(20); $back = $false
        while (-not $back) {
            Start-Sleep -Seconds 1
            if (Test-Path $logErr) {
                $fs = [IO.File]::Open($logErr, 'Open', 'Read', 'ReadWrite')
                try {
                    $fs.Position = $pos
                    $sr = New-Object IO.StreamReader($fs)
                    $newText = $sr.ReadToEnd(); $pos = $fs.Position
                } finally { $fs.Close() }
                foreach ($l in ($newText -split "`n")) {
                    if ($l -match 'OPEN "([^"]+)": 0') {
                        if ($sizes.ContainsKey($matches[1])) { $current = $matches[1]; $readCurrent = 0L }
                    } elseif ($l -match 'READ handle=\d+ size=\d+: (\d+)') {
                        $readCurrent += [long]$matches[1]; $readTotal += [long]$matches[1]; $lastRead = [DateTime]::Now
                    }
                }
            }
            $samples.Enqueue(@([DateTime]::Now, $readTotal)); while ($samples.Count -gt 15) { [void]$samples.Dequeue() }
            $speed = 0
            if ($samples.Count -ge 2) {
                $a = $samples.Peek(); $dt = ([DateTime]::Now - $a[0]).TotalSeconds
                if ($dt -gt 0) { $speed = ($readTotal - $a[1]) / $dt }
            }
            if ($current) {
                # all in double: with an integer 1, PowerShell 5.1 picks the 32-bit Max and breaks above 2 GB
                $pct = [int][math]::Min(100.0, [math]::Floor(100.0 * $readCurrent / [math]::Max(1.0, [double]$sizes[$current])))
                $left = if ($speed -gt 0) { Duration (($groupTotal - $readTotal) / $speed) } else { '?' }
                Write-Progress -Activity "Sending to the PS2: $current" -PercentComplete $pct `
                    -Status ("{0}%  {1} of {2}  {3:N1} MB/s  {4} left" -f $pct, (FormatSize $readCurrent), (FormatSize $sizes[$current]), ($speed / 1MB), $left)
            }
            # the FTP only comes back when the PS2 has finished everything
            if ([DateTime]::Now -gt $nextCheck) {
                $nextCheck = [DateTime]::Now.AddSeconds(10)
                if (Ps2Online) { $back = $true }
            }
            if ([DateTime]::Now -gt $deadline) { break }
            if (([DateTime]::Now - $lastRead).TotalMinutes -gt 10 -and $readTotal -gt 0) { $stopServer = $true; break }
        }
        Write-Progress -Activity 'Sending to the PS2' -Completed

        if (-not $back) {
            if ($stopServer) { Write-Host '  The PS2 stopped asking for data 10 minutes ago and the FTP did not come back. Look at the PS2 screen.' }
            else { Write-Host '  It is well past the expected time and the PS2 FTP has not come back yet. Look at the PS2 screen.' }
            Write-Host "  (server log: $logErr)"
            $summary += "NO ANSWER: $source"
            continue
        }
        $stopServer = $true   # the PS2 finished and went back to FTP

        # ---- 7. result ----
        Write-Host '  The FTP is back. Reading the result...'
        $resultLines = $null
        for ($t = 0; $t -lt 6 -and -not $resultLines; $t++) {
            Start-Sleep -Seconds 3
            $r = Rc cat "${remote}$result"
            if ($r.Ok -and ($r.Output -join "`n") -match 'FIM') { $resultLines = $r.Output }
        }
        if (-not $resultLines) { Write-Host '  Could not find the result on the HDD (ata0:/PS2-RECEBER.RES).'; $summary += "NO RESULT: $source"; continue }
        Rc deletefile "${remote}$result" | Out-Null
        foreach ($l in $resultLines) {
            $c = "$l".Split("`t")
            if ($c.Count -lt 4) { continue }
            $item = $g.Group | Where-Object { $_.File.Name -eq $c[3] } | Select-Object -First 1
            $txt = switch ($c[0]) {
                'OK'                     { 'arrived complete' }
                'JA_EXISTIA'             { 'was already on the HDD (left untouched)' }
                'FALHOU'                 { 'FAILED (error; nothing was left on the HDD)' }
                'CANCELADO'              { 'cancelled on the PS2 (nothing was left on the HDD)' }
                'NAO_FEITO'              { 'not done (a previous one failed)' }
                'SEM_SERVIDOR'           { 'the PS2 did not find the udpfs server (firewall?)' }
                'FICOU_EM_PS2-RECEBENDO' { 'copied, but stayed in ata0:/PS2-RECEBENDO (move it to the right folder)' }
                default                  { $c[0] }
            }
            if ($c[0] -eq 'OK' -and [int]$c[2] -gt 0) { $txt += (' in {0} ({1:N1} MB/s)' -f (Duration ([int]$c[2])), ([long]$c[1] / 1MB / [int]$c[2])) }
            $summary += "$($item.Folder)\$($c[3]): $txt"
        }
    } finally {
        if ($srv -and -not $srv.HasExited) {
            if ($stopServer) { Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue }
            else {
                Write-Host ''
                Write-Host '  The udpfs server is STILL RUNNING, because the PS2 may still be copying.'
                Write-Host '  When the PS2 is done, it is closed the next time you send games'
                Write-Host '  (or close "udpfsd.exe" in Task Manager).'
            }
        }
    }
}

if (-not $Simulate) {
    Write-Host ''
    Write-Host '  RESULT'
    $summary | ForEach-Object { Write-Host "    $_" }
    Write-Host ''
    Write-Host '  To use the P:, M: and H: drives again, run "Connect PS2.bat".'
}
Finish 0
