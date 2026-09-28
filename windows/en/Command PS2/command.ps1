# Sends a command to the PS2 over the network: open an app, go back to OSDMenu or power off.
# Needs the wLaunchELF FTP open on the PS2, sitting on the main menu.
#
# How it works: leaves, over FTP, a request on the PS2 HDD (ata0:/PS2-COMANDO.TXT). The LaunchELF checks every
# 3 s, deletes the request and runs it. The apps offered are the same as on the OSDMenu screen (read from
# OSDMENU.CNF), plus the option to type a path. Before sending, it checks over FTP that the ELF really exists.
# (The file name and keywords of the request are the protocol the LaunchELF understands: they stay as they are.)
#
# Without the menu (to use from another script): -Command MENU | POWEROFF | <ELF path, e.g. mmce0:/APPS/OPNPS2LD.ELF>
param([string]$Command)

$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$base    = Split-Path -Parent $here
$rclone  = Join-Path $base 'PS2 Drive\rclone.exe'
$disconn = Join-Path $base 'PS2 Drive\disconnect.ps1'
$ps2     = '192.168.1.111'
$pw      = 'URKHqrTKudapzjgXtN0h1gjuhw'   # "ps2" obscured for rclone (anonymous login)
# no_check_upload: the PS2 takes the request and stops the FTP within seconds (see "Send Games to PS2")
$remote  = ":ftp,host=$ps2,user=anonymous,pass=$pw,disable_epsv=true,disable_mlsd=true,no_check_upload=true:"
$job     = 'ata/0/PS2-COMANDO.TXT'

function Finish($code) { Write-Host ''; if (-not $env:PS2_NO_PAUSE) { Read-Host '  Press Enter to close' | Out-Null }; exit $code }
function Rc {
    $output = & $rclone @args --contimeout 10s --timeout 30s --low-level-retries 2 -q 2>&1
    return @{ Ok = ($LASTEXITCODE -eq 0); Output = $output }
}
function Ps2Online { Test-NetConnection $ps2 -Port 21 -InformationLevel Quiet -WarningAction SilentlyContinue }

# PS2 path (as the LaunchELF understands it) -> FTP path. Returns $null if the FTP cannot reach that place.
function FtpPath($c) {
    if ($c -match '^(mmce|mc)(\d):/?(.*)$') { return "$($matches[1])/$($matches[2])/$($matches[3])" }
    if ($c -match '^(ata|usb|mx4sio)(\d):/?(.*)$') { return "$($matches[1])/$($matches[2])/$($matches[3])" }
    if ($c -match '^mass(\d?):/?(.*)$') { $u = if ($matches[1]) { $matches[1] } else { '0' }; return "mass/$u/$($matches[2])" }
    return $null
}

# Tidies up what was typed: quotes, backslashes, "mmce?:" -> slot 0 (the SD2PSX is card 1)
function Normalize($c) {
    $c = $c.Trim().Trim('"').Trim()
    $c = $c -replace '\\', '/'
    $c = $c -replace '^(mmce|mc)\?:', '${1}0:'
    return $c
}

# Checks over FTP that the ELF exists. If it does, returns the path with the right spelling; if not, shows what
# is in the folder (ELFs and subfolders) to help and returns $null.
function CheckElf($c) {
    $ftp = FtpPath $c
    if (-not $ftp) {
        Write-Host "  Cannot check '$c' over FTP (use mmce0:/, mc0:/, mass:/, usb0:/ or ata0:/)."
        Write-Host '  The LaunchELF does not open ELFs from hdd0 (APA HDD) this way either.'
        return $null
    }
    $folder = ($ftp -replace '/[^/]*$', '')
    $name   = ($ftp -replace '^.*/', '')
    $r = Rc lsf "${remote}$folder" --max-depth 1
    if (-not $r.Ok) {
        Write-Host "  The folder '$($c -replace '/[^/]*$', '')/' does not exist on the PS2."
        return $null
    }
    $items = @($r.Output | ForEach-Object { "$_" })
    $found = $items | Where-Object { $_ -ieq $name } | Select-Object -First 1
    if ($found) {
        if ($found -notmatch '\.elf$') { Write-Host "  Warning: '$found' does not end in .ELF; the LaunchELF may refuse it." }
        return ($c -replace '[^/]+$', $found)   # '+': with '*' the empty match at the end also matched and the name came out doubled
    }
    Write-Host "  There is no '$name' in '$($c -replace '/[^/]*$', '')/'."
    $elfs = $items | Where-Object { $_ -match '\.elf$' }
    $folders = $items | Where-Object { $_ -match '/$' }
    if ($elfs) { Write-Host '  ELFs in that folder:'; $elfs | ForEach-Object { Write-Host "    $_" } }
    if ($folders) { Write-Host "  Subfolders: $(($folders | Select-Object -First 15) -join '  ')" }
    return $null
}

Write-Host ''
Write-Host '  COMMAND PS2'
Write-Host ''
if (-not (Ps2Online)) {
    Write-Host '  The PS2 did not answer. Open "wLaunchELF FTP" on the PS2 (from OSDMenu) and leave it on the main menu.'
    Finish 1
}

# ---- the P:/M:/H: drives go first: the command is going to take the FTP down, and reading the card/memory card
# (the OSDMenu list, the ELF check) together with an upload from P: would break the upload on the SD2PSX ----
if (Get-CimInstance Win32_Process -Filter "Name='rclone.exe'" | Where-Object { $_.CommandLine -match 'mount ' }) {
    Write-Host '  Disconnecting the P:, M: and H: drives (waiting for what was being uploaded to finish)...'
    Write-Host '  Afterwards, to use them again, run "Connect PS2.bat".'
    & powershell -NoProfile -ExecutionPolicy Bypass -File $disconn | Out-Null
    Write-Host ''
}

# ---- what to do ----
if (-not $Command) {
    $options = @()
    $r = Rc cat "${remote}mc/0/SYS-CONF/OSDMENU.CNF"
    if ($r.Ok) {
        $names = @{}; $paths = @{}
        foreach ($l in $r.Output) {
            if ("$l" -match '^name_OSDSYS_ITEM_(\d+)\s*=\s*(.+?)\s*$') { $names[[int]$matches[1]] = $matches[2] }
            elseif ("$l" -match '^path1_OSDSYS_ITEM_(\d+)\s*=\s*(.+?)\s*$') { $paths[[int]$matches[1]] = $matches[2] }
        }
        foreach ($n in ($names.Keys | Sort-Object)) {
            $c = $paths[$n]
            if (-not $c) { continue }
            $c = Normalize $c
            if ($c -eq 'OSDSYS') { $c = 'MENU' }
            elseif ($c -eq 'POWEROFF') { $c = 'POWEROFF' }
            elseif (-not (FtpPath $c)) { continue }         # e.g. PSBBN on hdd0: only through OSDMenu
            if ($c -match 'wLaunchELF-FTP') { continue }       # already open
            $options += [pscustomobject]@{ Name = $names[$n]; Command = $c }
        }
    }
    if (-not ($options | Where-Object { $_.Command -eq 'MENU' })) { $options += [pscustomobject]@{ Name = 'Back to OSDMenu'; Command = 'MENU' } }
    if (-not ($options | Where-Object { $_.Command -eq 'POWEROFF' })) { $options += [pscustomobject]@{ Name = 'Power off'; Command = 'POWEROFF' } }

    for ($i = 0; $i -lt $options.Count; $i++) {
        $detail = if ($options[$i].Command -eq 'MENU') { 'goes back to the OSDMenu screen' } elseif ($options[$i].Command -eq 'POWEROFF') { 'powers the PS2 off' } else { $options[$i].Command }
        Write-Host ('  {0} - {1}   ({2})' -f ($i + 1), $options[$i].Name, $detail)
    }
    $typeIt = $options.Count + 1
    Write-Host ('  {0} - type a path   (e.g. mmce0:/APPS/MyApp/app.elf)' -f $typeIt)
    Write-Host '  0 - cancel'
    Write-Host ''
    $choice = Read-Host '  Number'
    if ($choice -match '^\d+$' -and [int]$choice -eq $typeIt) {
        # type it: asks again while the path does not exist (empty Enter gives up)
        while ($true) {
            Write-Host ''
            $c = Read-Host '  ELF path (empty Enter cancels)'
            if (-not $c.Trim()) { Write-Host '  Nothing done.'; Finish 0 }
            $c = CheckElf (Normalize $c)
            if ($c) { $Command = $c; break }
        }
    } elseif (-not ($choice -match '^\d+$') -or [int]$choice -lt 1 -or [int]$choice -gt $options.Count) {
        Write-Host '  Nothing done.'; Finish 0
    } else {
        $Command = $options[[int]$choice - 1].Command
    }
}

switch -Regex ($Command) {
    '^MENU$'     { $line = 'MENU' }
    '^POWEROFF$' { $line = 'DESLIGAR' }
    default {
        # any path (from the list, typed or coming from -Command) is checked before going to the PS2
        $c = CheckElf (Normalize $Command)
        if (-not $c) { Write-Host '  Nothing was sent.'; Finish 1 }
        $line = "EXECUTAR`t$c"
    }
}

# ---- sends it and waits for the PS2 to take it ----
$tmp = Join-Path $env:TEMP 'PS2-COMANDO.TXT'
[IO.File]::WriteAllText($tmp, "PS2-COMANDO 1`n$line`nFIM`n", [Text.Encoding]::ASCII)
$r = Rc copyto $tmp "${remote}$job" --inplace
$delivered = $r.Ok
Write-Host "  Sent: $($line -replace "`t", ' ')"

$taken = $false
for ($t = 0; $t -lt 8 -and -not $taken; $t++) {
    Start-Sleep -Seconds 2
    if (-not (Ps2Online)) { $taken = $true; break }          # the new app already opened (the FTP went down)
    $r = Rc lsf "${remote}ata/0"
    if ($r.Ok) {
        if ($r.Output -contains 'PS2-COMANDO.TXT') { $delivered = $true }
        elseif ($delivered) { $taken = $true }
    }
}
if (-not $taken) {
    Rc deletefile "${remote}$job" | Out-Null
    Write-Host ''
    Write-Host '  The PS2 did not take the command within 16 s (and I cancelled it). Check whether the LaunchELF'
    Write-Host '  on the PS2 is this wLaunchELF FTP and whether it is on the main menu (inside the FileBrowser it does not look for requests).'
    Finish 1
}
Write-Host '  The PS2 took the command.'
Finish 0
