# Manda jogos (ISOs) do PC pro HD do PS2, na velocidade do udpfs, sem mexer no controle.
# Precisa da R9 do wLaunchELF FTP aberta no PS2, parada no menu principal.
#
# Como funciona: este script serve a pasta dos jogos com o udpfsd (so leitura) e, pelo FTP, deixa um
# pedido no HD do PS2 (ata0:/PS2-RECEBER.TXT). O LaunchELF ve o pedido, troca a rede pro udpfs (o FTP
# desliga), copia cada jogo pra ata0:/DVD ou ata0:/CD, grava ata0:/PS2-RECEBER.RES e volta pro FTP.
# Aqui a gente acompanha pelo log do udpfsd e, quando o FTP volta, le o resultado.
#
# -Simular: faz tudo menos falar com o PS2 (confere os arquivos, decide CD/DVD, monta o pedido).
param(
    [switch]$Simular,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Itens
)

$aqui    = Split-Path -Parent $MyInvocation.MyCommand.Path
$base    = Split-Path -Parent $aqui
$rclone  = Join-Path $base 'Unidade do PS2\rclone.exe'
$udpfsd  = Join-Path $base 'udpfsd\udpfsd.exe'
$descon  = Join-Path $base 'Unidade do PS2\desconectar.ps1'
$ps2     = '192.168.1.111'
$pw      = 'URKHqrTKudapzjgXtN0h1gjuhw'   # "ps2" obscurecida pro rclone (login anonimo)
# no_check_upload: o rclone confere o arquivo depois de gravar, mas o PS2 pega o pedido e desliga o FTP
# em segundos, e a conferencia falhava mesmo com o pedido entregue (27/09)
$remoto  = ":ftp,host=$ps2,user=anonymous,pass=$pw,disable_epsv=true,disable_mlsd=true,no_check_upload=true:"
$pedido  = 'ata/0/PS2-RECEBER.TXT'
$result  = 'ata/0/PS2-RECEBER.RES'
$mbps    = 2.8   # medido em 27/09: udpfs do PC ate o HD

function Fim($codigo) { Write-Host ''; if (-not $env:PS2_SEM_PAUSA) { Read-Host '  Enter para fechar' | Out-Null }; exit $codigo }
function Tam($b) { if ($b -ge 1GB) { '{0:N2} GB' -f ($b / 1GB) } else { '{0:N0} MB' -f ($b / 1MB) } }
function Tempo($s) {
    if ($s -ge 3600) { return '{0} h {1:00} min' -f [math]::Floor($s / 3600), [math]::Floor(($s % 3600) / 60) }
    if ($s -ge 60) { return '{0} min' -f [math]::Ceiling($s / 60) }
    return '{0} s' -f [math]::Ceiling($s)
}
function Rc {
    # uma conexao FTP por comando; so mexe no HD (ata), nunca no cartao do SD2PSX
    $saida = & $rclone @args --contimeout 10s --timeout 30s --low-level-retries 2 -q 2>&1
    return @{ Ok = ($LASTEXITCODE -eq 0); Saida = $saida }
}
function Ps2Ligado { Test-NetConnection $ps2 -Port 21 -InformationLevel Quiet -WarningAction SilentlyContinue }

# CD ou DVD: jogo de DVD do PS2 tem UDF (descritores NSR02/NSR03 logo depois do setor 16); CD so tem ISO9660
function TipoDoJogo($arquivo) {
    $fs = [IO.File]::OpenRead($arquivo.FullName)
    try {
        $buf = New-Object byte[] 32768
        $fs.Position = 32768
        $n = $fs.Read($buf, 0, $buf.Length)
    } finally { $fs.Close() }
    $txt = [Text.Encoding]::ASCII.GetString($buf, 0, $n)
    if ($txt.Contains('NSR02') -or $txt.Contains('NSR03')) { return 'DVD' }
    if ($arquivo.Length -gt 900MB) { return 'DVD' }
    return 'CD'
}

Write-Host ''
Write-Host ('  MANDAR JOGOS PRO PS2 (udpfs)' + $(if ($Simular) { '  -- SIMULACAO, o PS2 nao e tocado' } else { '' }))
Write-Host ''

# ---- 1. os arquivos ----
$jogos = @()
foreach ($i in $Itens) {
    if (-not $i) { continue }
    if (Test-Path -LiteralPath $i -PathType Container) {
        $jogos += Get-ChildItem -LiteralPath $i -File | Where-Object { $_.Extension -ieq '.iso' }
    } elseif (Test-Path -LiteralPath $i -PathType Leaf) {
        $jogos += Get-Item -LiteralPath $i
    } else {
        Write-Host "  Nao achei: $i"
    }
}
if (-not $jogos) {
    Write-Host '  Arraste as ISOs (ou a pasta delas) pra cima do "Mandar jogos pro PS2.bat".'
    Fim 1
}

$validos = @()
foreach ($j in $jogos) {
    $motivo = $null
    if ($j.Extension -ine '.iso') { $motivo = 'so ISO (.iso)' }
    elseif ($j.Name -notmatch '^[\x20-\x7E]+$') { $motivo = 'nome com acento ou simbolo especial: renomeie so com letras sem acento' }
    elseif ($j.Name.Length -gt 200) { $motivo = 'nome comprido demais' }
    elseif ($j.Length -eq 0) { $motivo = 'arquivo vazio' }
    if ($motivo) { Write-Host "  PULANDO $($j.Name): $motivo"; continue }
    $validos += [pscustomobject]@{ Arquivo = $j; Pasta = (TipoDoJogo $j); Tamanho = $j.Length }
}
if (-not $validos) { Fim 1 }

# ---- 2. o HD do PS2: o que ja existe la ----
if ($Simular) {
    Write-Host '  (simulacao: nao confiro o que ja existe no HD do PS2)'
} else {
    Write-Host "  Procurando o PS2 em $ps2 ..."
    if (-not (Ps2Ligado)) {
        Write-Host '  O PS2 nao respondeu. Abra o "wLaunchELF FTP" (R9 ou mais nova) pelos Apps do RiptOPL,'
        Write-Host '  espere o IP aparecer e deixe ele no menu principal.'
        Fim 1
    }
    # as unidades P:/M:/H: usam o FTP, que vai desligar durante a copia: desconecta antes
    if (Get-CimInstance Win32_Process -Filter "Name='rclone.exe'" | Where-Object { $_.CommandLine -match 'mount ' }) {
        Write-Host '  Desconectando as unidades P:, M: e H: (o FTP do PS2 vai desligar durante a copia)...'
        & powershell -NoProfile -ExecutionPolicy Bypass -File $descon | Out-Null
    }
    $existentes = @{}
    foreach ($p in 'DVD', 'CD') {
        $r = Rc lsf "${remoto}ata/0/$p"
        if ($r.Ok) { foreach ($n in $r.Saida) { $existentes["$p/$n"] = $true } }
    }
    $r = Rc lsf "${remoto}ata/0"
    if (-not $r.Ok) {
        Write-Host '  Nao consegui ler o HD do PS2 (ata0:). O HD esta ligado no PS2?'
        Fim 1
    }
    if ($r.Saida -contains 'PS2-RECEBER.TXT') {
        Write-Host '  Ja existe um pedido la (de uma vez que nao terminou). Apagando ele primeiro.'
        Rc deletefile "${remoto}$pedido" | Out-Null
    }
    if ($r.Saida -contains 'PS2-RECEBER.RES') { Rc deletefile "${remoto}$result" | Out-Null }
    $novos = @()
    foreach ($v in $validos) {
        if ($existentes["$($v.Pasta)/$($v.Arquivo.Name)"]) { Write-Host "  JA ESTA NO HD, pulando: $($v.Pasta)\$($v.Arquivo.Name)" }
        else { $novos += $v }
    }
    $validos = $novos
    if (-not $validos) { Write-Host '  Nada novo pra mandar.'; Fim 0 }
}

# ---- 3. um envio por pasta de origem (o udpfsd serve uma pasta so) ----
$grupos = $validos | Group-Object { $_.Arquivo.DirectoryName }
$total = ($validos | Measure-Object Tamanho -Sum).Sum
Write-Host ''
foreach ($v in $validos) { Write-Host ('  {0,-4} {1,9}  {2}' -f $v.Pasta, (Tam $v.Tamanho), $v.Arquivo.Name) }
Write-Host ''
Write-Host ("  Total: {0} em {1} jogo(s). Estimativa: ~{2} (a ~{3} MB/s)." -f (Tam $total), $validos.Count, (Tempo ($total / 1MB / $mbps)), $mbps)
Write-Host ''

$resumo = @()
foreach ($g in $grupos) {
    $origem = $g.Name
    $linhas = @('PS2-RECEBER 1') + ($g.Group | ForEach-Object { "$($_.Pasta)`t$($_.Tamanho)`t$($_.Arquivo.Name)" }) + @('FIM')
    $textoPedido = ($linhas -join "`n") + "`n"
    if ($Simular) {
        Write-Host "  [simulacao] serviria a pasta: $origem"
        Write-Host '  [simulacao] pedido que iria pro PS2 (ata0:/PS2-RECEBER.TXT):'
        $linhas | ForEach-Object { Write-Host "      $($_ -replace "`t", ' | ')" }
        Write-Host ''
        continue
    }

    # ---- 4. servidor udpfs (so leitura, sem descompressao automatica de ZSO/CSO) ----
    Get-Process udpfsd -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host '  Fechando um servidor udpfs que tinha ficado aberto de uma vez anterior.'; Stop-Process -Id $_.Id -Force }
    $logErr = Join-Path $env:TEMP 'ps2-mandar-udpfsd.log'
    $logOut = Join-Path $env:TEMP 'ps2-mandar-udpfsd.out.log'
    $arg = "-fsroot `"$($origem.TrimEnd('\'))`" -ro -no-compression -verbose"
    if ($origem.EndsWith('\')) { $arg = "-fsroot `"$origem.`" -ro -no-compression -verbose" }
    $srv = Start-Process -FilePath $udpfsd -ArgumentList $arg -WindowStyle Hidden -PassThru `
        -RedirectStandardError $logErr -RedirectStandardOutput $logOut
    Start-Sleep -Seconds 2
    if ($srv.HasExited) { Write-Host "  O udpfsd nao abriu. Veja $logErr"; Fim 1 }

    # o servidor so e desligado quando e certo que o PS2 nao esta lendo dele (desligar no meio corta a copia)
    $pararServidor = $false
    try {
        # ---- 5. o pedido ----
        $tmp = Join-Path $env:TEMP 'PS2-RECEBER.TXT'
        [IO.File]::WriteAllText($tmp, $textoPedido, [Text.Encoding]::ASCII)
        $r = Rc copyto $tmp "${remoto}$pedido" --inplace
        $entregue = $r.Ok
        Write-Host '  Pedido enviado. Esperando o PS2 pegar (ele confere a cada 3 s, no menu principal)...'

        # pegou = o pedido sumiu do HD, ou o FTP sumiu (o PS2 ja trocou a rede pro udpfs)
        $pegou = $false
        for ($t = 0; $t -lt 20 -and -not $pegou; $t++) {
            if (-not (Ps2Ligado)) { $pegou = $true; break }
            $r = Rc lsf "${remoto}ata/0"
            if ($r.Ok) {
                if ($r.Saida -contains 'PS2-RECEBER.TXT') { $entregue = $true }
                elseif ($entregue) { $pegou = $true; break }
            }
            Start-Sleep -Seconds 2
        }
        if (-not $pegou) {
            Rc deletefile "${remoto}$pedido" | Out-Null
            $pararServidor = $true
            Write-Host ''
            if (-not $entregue) {
                Write-Host '  Nao consegui deixar o pedido no HD do PS2 pelo FTP.'
            } else {
                Write-Host '  O PS2 nao pegou o pedido em 40 s (e cancelei ele). Confira:'
                Write-Host '    - se o LaunchELF no PS2 e a R9 (as versoes antigas nao sabem receber);'
                Write-Host '    - se ele esta no menu principal (no FileBrowser ele nao olha o pedido).'
            }
            Fim 1
        }
        Write-Host '  O PS2 pegou o pedido e esta trocando a rede pro udpfs.'
        Write-Host ''

        # ---- 6. acompanhando pelo log do udpfsd ----
        $tamanhos = @{}; foreach ($v in $g.Group) { $tamanhos[$v.Arquivo.Name] = $v.Tamanho }
        $somaGrupo = ($g.Group | Measure-Object Tamanho -Sum).Sum
        $limite = [DateTime]::Now.AddSeconds($somaGrupo / 1MB / 0.5 + 300)   # bem folgado: 0,5 MB/s + 5 min
        $atual = $null; $lidoAtual = 0L; $lidoTotal = 0L; $pos = 0L
        $amostras = New-Object System.Collections.Queue
        $ultimoLido = [DateTime]::Now; $proxChecagem = [DateTime]::Now.AddSeconds(20); $voltou = $false
        while (-not $voltou) {
            Start-Sleep -Seconds 1
            if (Test-Path $logErr) {
                $fs = [IO.File]::Open($logErr, 'Open', 'Read', 'ReadWrite')
                try {
                    $fs.Position = $pos
                    $sr = New-Object IO.StreamReader($fs)
                    $novo = $sr.ReadToEnd(); $pos = $fs.Position
                } finally { $fs.Close() }
                foreach ($l in ($novo -split "`n")) {
                    if ($l -match 'OPEN "([^"]+)": 0') {
                        if ($tamanhos.ContainsKey($matches[1])) { $atual = $matches[1]; $lidoAtual = 0L }
                    } elseif ($l -match 'READ handle=\d+ size=\d+: (\d+)') {
                        $lidoAtual += [long]$matches[1]; $lidoTotal += [long]$matches[1]; $ultimoLido = [DateTime]::Now
                    }
                }
            }
            $amostras.Enqueue(@([DateTime]::Now, $lidoTotal)); while ($amostras.Count -gt 15) { [void]$amostras.Dequeue() }
            $velo = 0
            if ($amostras.Count -ge 2) {
                $a = $amostras.Peek(); $dt = ([DateTime]::Now - $a[0]).TotalSeconds
                if ($dt -gt 0) { $velo = ($lidoTotal - $a[1]) / $dt }
            }
            if ($atual) {
                # tudo em double: com um 1 inteiro o PowerShell 5.1 escolhe o Max de 32 bits e quebra acima de 2 GB
                $pct = [int][math]::Min(100.0, [math]::Floor(100.0 * $lidoAtual / [math]::Max(1.0, [double]$tamanhos[$atual])))
                $falta = if ($velo -gt 0) { Tempo (($somaGrupo - $lidoTotal) / $velo) } else { '?' }
                Write-Progress -Activity "Mandando pro PS2: $atual" -PercentComplete $pct `
                    -Status ("{0}%  {1} de {2}  {3:N1} MB/s  faltam {4}" -f $pct, (Tam $lidoAtual), (Tam $tamanhos[$atual]), ($velo / 1MB), $falta)
            }
            # o FTP so volta quando o PS2 terminou tudo
            if ([DateTime]::Now -gt $proxChecagem) {
                $proxChecagem = [DateTime]::Now.AddSeconds(10)
                if (Ps2Ligado) { $voltou = $true }
            }
            if ([DateTime]::Now -gt $limite) { break }
            if (([DateTime]::Now - $ultimoLido).TotalMinutes -gt 10 -and $lidoTotal -gt 0) { $pararServidor = $true; break }
        }
        Write-Progress -Activity 'Mandando pro PS2' -Completed

        if (-not $voltou) {
            if ($pararServidor) { Write-Host '  O PS2 parou de pedir dados ha 10 minutos e o FTP nao voltou. Veja a tela do PS2.' }
            else { Write-Host '  Passou muito do tempo esperado e o FTP do PS2 ainda nao voltou. Veja a tela do PS2.' }
            Write-Host "  (log do servidor: $logErr)"
            $resumo += "SEM RESPOSTA: $origem"
            continue
        }
        $pararServidor = $true   # o PS2 terminou e voltou pro FTP

        # ---- 7. resultado ----
        Write-Host '  O FTP voltou. Lendo o resultado...'
        $linhasRes = $null
        for ($t = 0; $t -lt 6 -and -not $linhasRes; $t++) {
            Start-Sleep -Seconds 3
            $r = Rc cat "${remoto}$result"
            if ($r.Ok -and ($r.Saida -join "`n") -match 'FIM') { $linhasRes = $r.Saida }
        }
        if (-not $linhasRes) { Write-Host '  Nao achei o resultado no HD (ata0:/PS2-RECEBER.RES).'; $resumo += "SEM RESULTADO: $origem"; continue }
        Rc deletefile "${remoto}$result" | Out-Null
        foreach ($l in $linhasRes) {
            $c = "$l".Split("`t")
            if ($c.Count -lt 4) { continue }
            $item = $g.Group | Where-Object { $_.Arquivo.Name -eq $c[3] } | Select-Object -First 1
            $txt = switch ($c[0]) {
                'OK'                     { 'chegou inteiro' }
                'JA_EXISTIA'             { 'ja existia no HD (nao mexi)' }
                'FALHOU'                 { 'FALHOU (cancelado ou erro; nada ficou no HD)' }
                'NAO_FEITO'              { 'nao foi feito (um anterior falhou)' }
                'SEM_SERVIDOR'           { 'o PS2 nao achou o servidor udpfs (firewall?)' }
                'FICOU_EM_PS2-RECEBENDO' { 'copiou, mas ficou em ata0:/PS2-RECEBENDO (mova pra pasta certa)' }
                default                  { $c[0] }
            }
            if ($c[0] -eq 'OK' -and [int]$c[2] -gt 0) { $txt += (' em {0} ({1:N1} MB/s)' -f (Tempo ([int]$c[2])), ([long]$c[1] / 1MB / [int]$c[2])) }
            $resumo += "$($item.Pasta)\$($c[3]): $txt"
        }
    } finally {
        if ($srv -and -not $srv.HasExited) {
            if ($pararServidor) { Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue }
            else {
                Write-Host ''
                Write-Host '  O servidor udpfs CONTINUA LIGADO, porque o PS2 pode ainda estar copiando.'
                Write-Host '  Quando o PS2 terminar, ele fecha sozinho na proxima vez que voce mandar jogos'
                Write-Host '  (ou feche o "udpfsd.exe" no Gerenciador de Tarefas).'
            }
        }
    }
}

if (-not $Simular) {
    Write-Host ''
    Write-Host '  RESULTADO'
    $resumo | ForEach-Object { Write-Host "    $_" }
    Write-Host ''
    Write-Host '  Pra usar as unidades P:, M: e H: de novo, rode o "Conectar PS2.bat".'
}
Fim 0
