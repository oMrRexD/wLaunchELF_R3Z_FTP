# Janelinha "PS2 - envios": mostra o que esta subindo de verdade pro PS2.
# O Windows diz que a copia terminou assim que o arquivo chega no cache do PC; o envio pro PS2
# acontece depois, na velocidade da rede do PS2. Esta janela aparece sozinha quando ha envio,
# mostra arquivo, porcentagem, velocidade e quanto falta, e se esconde quando termina.
# O conectar.ps1 abre ela; ela fecha sozinha quando as unidades sao desconectadas.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$portas = 5572, 5574   # SD2PSX (P: e M:) e HD (H:)

function Rc($porta, $comando) {
    try { Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$porta/$comando" -Body '{}' -ContentType 'application/json' -TimeoutSec 2 }
    catch { $null }
}
function Tamanho($b) {
    if ($b -ge 1GB) { '{0:N1} GB' -f ($b / 1GB) } elseif ($b -ge 1MB) { '{0:N1} MB' -f ($b / 1MB) } else { '{0:N0} KB' -f ($b / 1KB) }
}
function Tempo($s) {
    if ($null -eq $s -or $s -le 0) { return '?' }
    if ($s -ge 3600) { return '{0} h {1:00} min' -f [math]::Floor($s / 3600), [math]::Floor(($s % 3600) / 60) }
    if ($s -ge 60) { return '{0} min' -f [math]::Ceiling($s / 60) }
    '{0} s' -f [math]::Ceiling($s)
}

$form = New-Object Windows.Forms.Form
$form.Text = 'PS2 - envios'
$form.Size = New-Object Drawing.Size(600, 200)
$form.FormBorderStyle = 'FixedToolWindow'
$form.StartPosition = 'Manual'
$area = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Location = New-Object Drawing.Point(($area.Right - 610), ($area.Bottom - 210))
$form.ShowInTaskbar = $true
$texto = New-Object Windows.Forms.Label
$texto.Dock = 'Fill'
$texto.Font = New-Object Drawing.Font('Consolas', 10)
$texto.Padding = New-Object Windows.Forms.Padding(8)
$form.Controls.Add($texto)

$estado = @{ Enviando = $false; JaEnviou = $false; Ocioso = [DateTime]::Now; Minimizou = $false; SemMontagem = 0; Pendentes = @{} }

$relogio = New-Object Windows.Forms.Timer
$relogio.Interval = 2000
$relogio.Add_Tick({
    $linhas = @(); $pendentes = 0; $falha = ''
    # montagem existe enquanto houver rclone rodando (o rc pode demorar a responder no meio de um envio)
    $algumaMontagem = [bool](Get-Process rclone -ErrorAction SilentlyContinue)
    foreach ($porta in $portas) {
        $st = Rc $porta 'core/stats'
        if (-not $st) { continue }
        # so os envios: a origem e o cache do PC (as leituras vem do FTP)
        $envios = @($st.transferring | Where-Object { $_ -and "$($_.srcFs)" -notlike ':ftp*' })
        $vfs = Rc $porta 'vfs/stats'
        if ($vfs) {
            $estado.Pendentes[$porta] = [int]$vfs.diskCache.uploadsInProgress + [int]$vfs.diskCache.uploadsQueued
        } elseif ($envios.Count -gt [int]$estado.Pendentes[$porta]) {
            $estado.Pendentes[$porta] = $envios.Count   # ocupado demais pra responder: pelo menos o que esta subindo
        }
        $pendentes += [int]$estado.Pendentes[$porta]
        foreach ($t in $envios) {
            $nome = Split-Path $t.name -Leaf
            if ($nome.Length -gt 34) { $nome = $nome.Substring(0, 31) + '...' }
            $linhas += '  {0}' -f $nome
            $linhas += '     {0,3}%   {1} de {2}   {3}/s   faltam {4}' -f $t.percentage, (Tamanho $t.bytes), (Tamanho $t.size), (Tamanho $t.speed), (Tempo $t.eta)
        }
        if ($st.lastError -and $pendentes -gt 0) { $falha = "$($st.lastError)" }
    }

    if (-not $algumaMontagem) {
        # desconectado: fecha (espera 3 voltas pra nao fechar numa piscada)
        $estado.SemMontagem++
        if ($estado.SemMontagem -ge 3) { $form.Close() }
        return
    }
    $estado.SemMontagem = 0

    if ($pendentes -gt 0) {
        $cab = @('ENVIANDO PRO PS2 - NAO feche o LaunchELF nem desligue o PS2', '')
        if (-not $linhas) { $linhas = @('  preparando o envio...') }
        $fila = $pendentes - [math]::Max(1, $linhas.Count / 2)
        if ($fila -gt 0) { $linhas += "  e mais $fila arquivo(s) na fila" }
        if ($falha) {
            if ($falha.Length -gt 60) { $falha = $falha.Substring(0, 57) + '...' }
            $linhas += "  falhou e vai tentar de novo: $falha"
        }
        $texto.Text = ($cab + $linhas) -join "`r`n"
        $texto.ForeColor = [Drawing.Color]::DarkRed
        $form.TopMost = $true
        if ($form.WindowState -eq 'Minimized') { $form.WindowState = 'Normal' }
        $estado.Enviando = $true; $estado.JaEnviou = $true; $estado.Minimizou = $false
    } else {
        if ($estado.Enviando) {
            $estado.Enviando = $false; $estado.Ocioso = [DateTime]::Now
            [Console]::Beep(880, 150)
        }
        $inicio = if ($estado.JaEnviou) { 'Tudo enviado. Nada subindo pro PS2 agora.' } else { 'Nada subindo pro PS2 agora.' }
        $texto.Text = "$inicio`r`n`r`nQuando copiar algo pro P:, M: ou H:, o envio de verdade aparece aqui.`r`nPra sair do FTP ou desligar o PS2, use antes o ""Desconectar PS2.bat""."
        $texto.ForeColor = [Drawing.Color]::DarkGreen
        $form.TopMost = $false
        # some 15 s depois de ficar ocioso
        if (-not $estado.Minimizou -and ([DateTime]::Now - $estado.Ocioso).TotalSeconds -gt 15) {
            $form.WindowState = 'Minimized'; $estado.Minimizou = $true
        }
    }
})
$relogio.Start()
[Windows.Forms.Application]::Run($form)
