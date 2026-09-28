# Desmonta P:, M: e H: so depois de terminar de enviar para o PS2 o que foi gravado nelas.
# Se o PS2 ja estiver desligado, ou o envio ficar 2 minutos sem andar, nao espera mais: o que
# faltou fica no cache do PC e sobe sozinho na proxima vez que conectar.
$aqui = Split-Path -Parent $MyInvocation.MyCommand.Path
$rc   = Join-Path $aqui 'rclone.exe'
$ps2  = '192.168.1.111'
$base = Join-Path $env:LOCALAPPDATA 'PS2-rede'   # PS2-rede e PS2-rede-HD

function Ps2Ligado { Test-NetConnection $ps2 -Port 21 -InformationLevel Quiet -WarningAction SilentlyContinue }
function Rc($porta, $comando) {
    try { Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$porta/$comando" -Body '{}' -ContentType 'application/json' -TimeoutSec 10 }
    catch { $null }
}

# 5572 = SD2PSX (P: e M:), 5574 = HD (H:); 5573 era o M: da versao antiga (uma montagem por letra)
$portas = 5572, 5573, 5574
$processos = @{}
foreach ($porta in $portas) {
    $p = Get-CimInstance Win32_Process -Filter "Name='rclone.exe'" |
        Where-Object { $_.CommandLine -match "mount .*127\.0\.0\.1:$porta" }
    if ($p) { $processos[$porta] = $p }
}

# 1) espera os envios
foreach ($porta in $processos.Keys) {
    if (-not (Rc $porta 'core/version')) { continue }   # travada: so encerra, la embaixo
    $ultimoAvanco = [DateTime]::Now; $ultimosBytes = -1; $avisou = $false
    while ($true) {
        $st = Rc $porta 'core/stats'
        $bytes = [long]($st.bytes)
        if ($bytes -ne $ultimosBytes) { $ultimosBytes = $bytes; $ultimoAvanco = [DateTime]::Now }
        $vfs = Rc $porta 'vfs/stats'
        if (-not $vfs) {
            # o rc demora a responder no meio de um envio; so desiste se a montagem sumiu ou parou de andar
            if (-not (Get-Process -Id $processos[$porta].ProcessId -ErrorAction SilentlyContinue)) { break }
            if (([DateTime]::Now - $ultimoAvanco).TotalSeconds -gt 120) { break }
            $e = @($st.transferring | Where-Object { $_ -and "$($_.srcFs)" -notlike ':ftp*' }) | Select-Object -First 1
            if ($e) { Write-Host ('    {0}: {1}%' -f (Split-Path $e.name -Leaf), $e.percentage) }
            Start-Sleep -Seconds 2; continue
        }
        $falta = [int]$vfs.diskCache.uploadsInProgress + [int]$vfs.diskCache.uploadsQueued
        if ($falta -eq 0) { break }
        if (-not $avisou) { Write-Host '  Terminando de enviar os arquivos pendentes...'; $avisou = $true }
        $envios = @($st.transferring | Where-Object { $_ -and "$($_.srcFs)" -notlike ':ftp*' })
        if ($envios) {
            $e = $envios[0]
            Write-Host ('    faltam {0} arquivo(s) - {1}: {2}%' -f $falta, (Split-Path $e.name -Leaf), $e.percentage)
        } else {
            Write-Host "    faltam $falta arquivo(s)"
        }
        if (-not (Ps2Ligado)) {
            Write-Host "    O PS2 nao responde. $falta arquivo(s) ficam guardados no PC e sobem"
            Write-Host '    sozinhos na proxima vez que voce conectar.'
            break
        }
        if (([DateTime]::Now - $ultimoAvanco).TotalSeconds -gt 120) {
            Write-Host "    O envio esta ha 2 minutos sem andar ($($st.lastError))."
            Write-Host "    $falta arquivo(s) ficam guardados no PC e sobem na proxima vez que voce conectar."
            break
        }
        Start-Sleep -Seconds 3
    }
}

# 2) tira as letras que apontam pras montagens do PS2
foreach ($linha in (subst.exe)) {
    if ($linha -like "*=> $base*") { subst.exe $linha.Substring(0, 2) /d }
}
# e os nomes que o Conectar deu a elas (so os marcados como nossos), pra nao rotular outro disco
# que um dia pegue a mesma letra
foreach ($letra in 'P', 'M', 'H') {
    $chave = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\DriveIcons\$letra"
    if ((Get-ItemProperty -Path $chave -ErrorAction SilentlyContinue).PS2rede -ne 1) { continue }
    Remove-Item -Path "$chave\DefaultLabel" -Recurse -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $chave -Name 'PS2rede' -ErrorAction SilentlyContinue
    if (-not (Get-ChildItem $chave -ErrorAction SilentlyContinue) -and -not ((Get-Item $chave).Property)) {
        Remove-Item -Path $chave -ErrorAction SilentlyContinue
    }
}

# 3) fecha as montagens; travada, ou que nao saiu, e encerrada
foreach ($porta in $processos.Keys) {
    Rc $porta 'core/quit' | Out-Null
    $processos[$porta] | ForEach-Object { Wait-Process -Id $_.ProcessId -Timeout 15 -ErrorAction SilentlyContinue }
    $processos[$porta] | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host '  Pronto: unidades do PS2 desconectadas. Ja pode sair do FTP no PS2.'
Start-Sleep -Seconds 3
