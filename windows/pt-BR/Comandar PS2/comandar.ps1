# Manda um comando pro PS2 pela rede: abrir um app, voltar pro OSDMenu ou desligar.
# Precisa do wLaunchELF FTP (R11 ou mais nova) aberto no PS2, parado no menu principal.
#
# Como funciona: deixa, pelo FTP, um pedido no HD do PS2 (ata0:/PS2-COMANDO.TXT). O LaunchELF confere a cada
# 3 s, apaga o pedido e executa. Os apps oferecidos sao os mesmos da tela do OSDMenu (lidos do OSDMENU.CNF),
# mais a opcao de digitar um caminho. Antes de mandar, confere pelo FTP se o ELF existe mesmo.
#
# Sem menu (pra usar de outro script): -Comando MENU | DESLIGAR | <caminho do ELF, ex. mmce0:/APPS/OPNPS2LD.ELF>
param([string]$Comando)

$aqui   = Split-Path -Parent $MyInvocation.MyCommand.Path
$base   = Split-Path -Parent $aqui
$rclone = Join-Path $base 'Unidade do PS2\rclone.exe'
$descon = Join-Path $base 'Unidade do PS2\desconectar.ps1'
$ps2    = '192.168.1.111'
$pw     = 'URKHqrTKudapzjgXtN0h1gjuhw'   # "ps2" obscurecida pro rclone (login anonimo)
# no_check_upload: o PS2 pega o pedido e desliga o FTP em segundos (ver "Mandar jogos pro PS2")
$remoto = ":ftp,host=$ps2,user=anonymous,pass=$pw,disable_epsv=true,disable_mlsd=true,no_check_upload=true:"
$pedido = 'ata/0/PS2-COMANDO.TXT'

function Fim($codigo) { Write-Host ''; if (-not $env:PS2_SEM_PAUSA) { Read-Host '  Enter para fechar' | Out-Null }; exit $codigo }
function Rc {
    $saida = & $rclone @args --contimeout 10s --timeout 30s --low-level-retries 2 -q 2>&1
    return @{ Ok = ($LASTEXITCODE -eq 0); Saida = $saida }
}
function Ps2Ligado { Test-NetConnection $ps2 -Port 21 -InformationLevel Quiet -WarningAction SilentlyContinue }

# Caminho do PS2 (como o LaunchELF entende) -> caminho no FTP. Devolve $null se o FTP nao alcanca esse lugar.
function CaminhoFtp($c) {
    if ($c -match '^(mmce|mc)(\d):/?(.*)$') { return "$($matches[1])/$($matches[2])/$($matches[3])" }
    if ($c -match '^(ata|usb|mx4sio)(\d):/?(.*)$') { return "$($matches[1])/$($matches[2])/$($matches[3])" }
    if ($c -match '^mass(\d?):/?(.*)$') { $u = if ($matches[1]) { $matches[1] } else { '0' }; return "mass/$u/$($matches[2])" }
    return $null
}

# Arruma o que foi digitado: aspas, barras invertidas, "mmce?:" -> slot 0 (o SD2PSX e o cartao 1)
function Normalizar($c) {
    $c = $c.Trim().Trim('"').Trim()
    $c = $c -replace '\\', '/'
    $c = $c -replace '^(mmce|mc)\?:', '${1}0:'
    return $c
}

# Confere pelo FTP se o ELF existe. Se existir, devolve o caminho com a grafia certa; se nao, mostra o que tem
# na pasta (ELFs e subpastas) pra ajudar e devolve $null.
function ConferirElf($c) {
    $ftp = CaminhoFtp $c
    if (-not $ftp) {
        Write-Host "  Nao sei conferir '$c' pelo FTP (use mmce0:/, mc0:/, mass:/, usb0:/ ou ata0:/)."
        Write-Host '  O LaunchELF tambem nao abre ELF do hdd0 (HD APA) por aqui.'
        return $null
    }
    $pasta = ($ftp -replace '/[^/]*$', '')
    $nome  = ($ftp -replace '^.*/', '')
    $r = Rc lsf "${remoto}$pasta" --max-depth 1
    if (-not $r.Ok) {
        Write-Host "  A pasta '$($c -replace '/[^/]*$', '')/' nao existe no PS2."
        return $null
    }
    $itens = @($r.Saida | ForEach-Object { "$_" })
    $achado = $itens | Where-Object { $_ -ieq $nome } | Select-Object -First 1
    if ($achado) {
        if ($achado -notmatch '\.elf$') { Write-Host "  Aviso: '$achado' nao termina em .ELF; o LaunchELF pode recusar." }
        return ($c -replace '[^/]+$', $achado)   # '+': com '*' o vazio do fim tambem casava e o nome saia dobrado
    }
    Write-Host "  Nao existe '$nome' em '$($c -replace '/[^/]*$', '')/'."
    $elfs = $itens | Where-Object { $_ -match '\.elf$' }
    $pastas = $itens | Where-Object { $_ -match '/$' }
    if ($elfs) { Write-Host '  ELFs nessa pasta:'; $elfs | ForEach-Object { Write-Host "    $_" } }
    if ($pastas) { Write-Host "  Subpastas: $(($pastas | Select-Object -First 15) -join '  ')" }
    return $null
}

Write-Host ''
Write-Host '  COMANDAR PS2'
Write-Host ''
if (-not (Ps2Ligado)) {
    Write-Host '  O PS2 nao respondeu. Abra o "wLaunchELF FTP" no PS2 (pelo OSDMenu) e deixe no menu principal.'
    Fim 1
}

# ---- as unidades P:/M:/H: saem antes de tudo: o comando vai tirar o FTP do ar, e ler o cartao/memory card
# (a lista do OSDMenu, a conferencia do ELF) junto com um envio do P: derrubaria o envio no SD2PSX ----
if (Get-CimInstance Win32_Process -Filter "Name='rclone.exe'" | Where-Object { $_.CommandLine -match 'mount ' }) {
    Write-Host '  Desconectando as unidades P:, M: e H: (esperando terminar o que estava subindo)...'
    Write-Host '  Depois, pra usar elas de novo, rode o "Conectar PS2.bat".'
    & powershell -NoProfile -ExecutionPolicy Bypass -File $descon | Out-Null
    Write-Host ''
}

# ---- o que fazer ----
if (-not $Comando) {
    $opcoes = @()
    $r = Rc cat "${remoto}mc/0/SYS-CONF/OSDMENU.CNF"
    if ($r.Ok) {
        $nomes = @{}; $caminhos = @{}
        foreach ($l in $r.Saida) {
            if ("$l" -match '^name_OSDSYS_ITEM_(\d+)\s*=\s*(.+?)\s*$') { $nomes[[int]$matches[1]] = $matches[2] }
            elseif ("$l" -match '^path1_OSDSYS_ITEM_(\d+)\s*=\s*(.+?)\s*$') { $caminhos[[int]$matches[1]] = $matches[2] }
        }
        foreach ($n in ($nomes.Keys | Sort-Object)) {
            $c = $caminhos[$n]
            if (-not $c) { continue }
            $c = Normalizar $c
            if ($c -eq 'OSDSYS') { $c = 'MENU' }
            elseif ($c -eq 'POWEROFF') { $c = 'DESLIGAR' }
            elseif (-not (CaminhoFtp $c)) { continue }        # ex.: PSBBN no hdd0: so pelo OSDMenu
            if ($c -match 'wLaunchELF-FTP') { continue }       # ja esta aberto
            $opcoes += [pscustomobject]@{ Nome = $nomes[$n]; Comando = $c }
        }
    }
    if (-not ($opcoes | Where-Object { $_.Comando -eq 'MENU' })) { $opcoes += [pscustomobject]@{ Nome = 'Voltar pro OSDMenu'; Comando = 'MENU' } }
    if (-not ($opcoes | Where-Object { $_.Comando -eq 'DESLIGAR' })) { $opcoes += [pscustomobject]@{ Nome = 'Desligar'; Comando = 'DESLIGAR' } }

    for ($i = 0; $i -lt $opcoes.Count; $i++) {
        $detalhe = if ($opcoes[$i].Comando -eq 'MENU') { 'volta pra tela do OSDMenu' } elseif ($opcoes[$i].Comando -eq 'DESLIGAR') { 'desliga o PS2' } else { $opcoes[$i].Comando }
        Write-Host ('  {0} - {1}   ({2})' -f ($i + 1), $opcoes[$i].Nome, $detalhe)
    }
    $digitar = $opcoes.Count + 1
    Write-Host ('  {0} - digitar um caminho   (ex.: mmce0:/APPS/MeuApp/app.elf)' -f $digitar)
    Write-Host '  0 - cancelar'
    Write-Host ''
    $escolha = Read-Host '  Numero'
    if ($escolha -match '^\d+$' -and [int]$escolha -eq $digitar) {
        # digitar: pergunta de novo enquanto o caminho nao existir (Enter vazio desiste)
        while ($true) {
            Write-Host ''
            $c = Read-Host '  Caminho do ELF (Enter vazio cancela)'
            if (-not $c.Trim()) { Write-Host '  Nada feito.'; Fim 0 }
            $c = ConferirElf (Normalizar $c)
            if ($c) { $Comando = $c; break }
        }
    } elseif (-not ($escolha -match '^\d+$') -or [int]$escolha -lt 1 -or [int]$escolha -gt $opcoes.Count) {
        Write-Host '  Nada feito.'; Fim 0
    } else {
        $Comando = $opcoes[[int]$escolha - 1].Comando
    }
}

switch -Regex ($Comando) {
    '^MENU$'     { $linha = 'MENU' }
    '^DESLIGAR$' { $linha = 'DESLIGAR' }
    default {
        # qualquer caminho (da lista, digitado ou vindo de -Comando) e conferido antes de ir pro PS2
        $c = ConferirElf (Normalizar $Comando)
        if (-not $c) { Write-Host '  Nao mandei nada.'; Fim 1 }
        $linha = "EXECUTAR`t$c"
    }
}

# ---- manda e espera o PS2 pegar ----
$tmp = Join-Path $env:TEMP 'PS2-COMANDO.TXT'
[IO.File]::WriteAllText($tmp, "PS2-COMANDO 1`n$linha`nFIM`n", [Text.Encoding]::ASCII)
$r = Rc copyto $tmp "${remoto}$pedido" --inplace
$entregue = $r.Ok
Write-Host "  Mandado: $($linha -replace "`t", ' ')"

$pegou = $false
for ($t = 0; $t -lt 8 -and -not $pegou; $t++) {
    Start-Sleep -Seconds 2
    if (-not (Ps2Ligado)) { $pegou = $true; break }          # o app novo ja abriu (o FTP saiu do ar)
    $r = Rc lsf "${remoto}ata/0"
    if ($r.Ok) {
        if ($r.Saida -contains 'PS2-COMANDO.TXT') { $entregue = $true }
        elseif ($entregue) { $pegou = $true }
    }
}
if (-not $pegou) {
    Rc deletefile "${remoto}$pedido" | Out-Null
    Write-Host ''
    Write-Host '  O PS2 nao pegou o comando em 16 s (e cancelei ele). Confira se o wLaunchELF FTP e a'
    Write-Host '  R11 ou mais nova e se ele esta no menu principal (no FileBrowser ele nao olha os pedidos).'
    Fim 1
}
Write-Host '  O PS2 pegou o comando.'
Fim 0
