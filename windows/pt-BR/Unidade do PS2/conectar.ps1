# Monta o FTP do PS2 como unidades do Windows:
#   P: = cartao do SD2PSX (mmce/0)   M: = memory card em uso (mc/0)   H: = exFAT do HD (ata/0)
#
# Duas montagens, cada uma numa pasta escondida em %LOCALAPPDATA%, e as letras apontam pra dentro delas (subst):
#   PS2-rede    -> P: e M:  (tudo que passa pelo SD2PSX) com UMA conexao so. O SD2PSX nao aguenta duas
#                  operacoes ao mesmo tempo: listar uma pasta no meio de uma gravacao derruba a gravacao
#                  ("Local write failed", testado em 27/09). Com uma conexao, o PC faz uma coisa por vez.
#   PS2-rede-HD -> H:  tambem com UMA conexao. O HD aguentaria duas, mas a rede do PS2 aguenta 5 conexoes ao
#                  todo (comando + dados) e, com 2 no H:, o Explorer abrindo o P: enquanto o H: calculava o
#                  espaco livre passou de 5 e o PS2 derrubou uma (28/09). Com 1 + 1, o pior caso e 4.
# A janelinha "PS2 - envios" (monitor.ps1) mostra o que esta subindo de verdade: o Windows diz que a
# copia terminou assim que o arquivo chega no cache do PC, e o envio pro PS2 so comeca depois.
# Precisa do WinFsp instalado e do PS2 com o wLaunchELF FTP aberto (o FTP liga sozinho).
$aqui  = Split-Path -Parent $MyInvocation.MyCommand.Path
$rc    = Join-Path $aqui 'rclone.exe'
$ps2   = '192.168.1.111'
$log   = Join-Path $env:TEMP 'ps2-unidade.log'
# Espaco livre: o FTP nao informa, e o rclone mostra 1 PB. So no H: da pra calcular de verdade: tamanho da
# particao exFAT (444 GiB, formatada em 25/09 junto com o PSBBN) menos a soma dos arquivos, que o rclone refaz
# varrendo o HD pelo FTP (~4 s) a cada --dir-cache-time (por isso 5 min no H:). P: e M: sao a mesma montagem
# (uma conexao so pro SD2PSX), entao nao da pra ter numero certo pra cada um: ficam com o 1 PB, que pelo menos
# nunca faz o Windows recusar uma copia por falta de espaco.
$montagens = @(
    @{ Pasta = Join-Path $env:LOCALAPPDATA 'PS2-rede';    Remoto = '';      Conexoes = 1; Porta = 5572;
       Extras = @('--dir-cache-time', '5s') },
    @{ Pasta = Join-Path $env:LOCALAPPDATA 'PS2-rede-HD'; Remoto = 'ata/0'; Conexoes = 1; Porta = 5574;
       Extras = @('--dir-cache-time', '5m', '--vfs-used-is-size', '--vfs-disk-space-total-size', '444G') }
)
# nome de cada letra no Explorer. O Windows so usa o nome do registro (DriveIcons\<letra>\DefaultLabel) quando o
# volume nao tem nome, por isso as montagens sobem com --volname " " (sai vazio). O acento vai via [char].
$letras = @(
    @{ Letra = 'P:'; Alvo = Join-Path $montagens[0].Pasta 'mmce\0'; Nome = 'cartao do SD2PSX';  Rotulo = "Cart$([char]0xE3)o do SD2PSX" },
    @{ Letra = 'M:'; Alvo = Join-Path $montagens[0].Pasta 'mc\0';   Nome = 'memory card em uso'; Rotulo = 'Memory Card do PS2' },
    @{ Letra = 'H:'; Alvo = $montagens[1].Pasta;                    Nome = 'HD do PS2 (exFAT)';  Rotulo = 'HD do PS2' }
)
$icones = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\DriveIcons'

# montada = a pasta existe e mostra o que tem no PS2
function Montada($m) { [bool](Get-ChildItem -LiteralPath $m.Pasta -Force -ErrorAction SilentlyContinue | Select-Object -First 1) }

function Fim($codigo) { Write-Host ''; Read-Host '  Enter para fechar' | Out-Null; exit $codigo }

if (-not (Test-Path 'C:\Program Files (x86)\WinFsp\bin\winfsp-x64.dll')) {
    Write-Host ''
    Write-Host '  Falta o WinFsp. Instale o winfsp-2.1.25156.msi desta pasta e rode de novo.'
    Fim 1
}

Write-Host ''
Write-Host "  Procurando o PS2 em $ps2 ..."
if (-not (Test-NetConnection $ps2 -Port 21 -InformationLevel Quiet -WarningAction SilentlyContinue)) {
    Write-Host ''
    Write-Host '  O PS2 nao respondeu. No PS2: abra o "wLaunchELF FTP" pelos Apps do RiptOPL'
    Write-Host '  e espere o IP aparecer na tela.'
    Fim 1
}

# O servidor aceita login anonimo; o rclone so exige a senha "obscurecida" (a de "ps2").
# Ela fica fixa porque entra no nome da pasta de cache: fixa, cada montagem usa sempre a mesma
# pasta, e o que ficou sem enviar (PS2 desligado antes da hora) sobe sozinho na proxima conexao.
$pw = 'URKHqrTKudapzjgXtN0h1gjuhw'

foreach ($m in $montagens) {
    if (Montada $m) { continue }
    # sobra de uma montagem que caiu: o WinFsp exige que a pasta nao exista. So apaga se estiver vazia.
    if (Test-Path $m.Pasta) { try { [IO.Directory]::Delete($m.Pasta) } catch { } }

    # conexao parada fecha em 15 s, pra nao segurar vaga no PS2 a toa
    $remote = ":ftp,host=$ps2,user=anonymous,pass=$pw,disable_epsv=true,disable_mlsd=true,idle_timeout=15s,concurrency=$($m.Conexoes):$($m.Remoto)"
    $argumentos = @(
        'mount', "`"$remote`"", "`"$($m.Pasta)`"", '--volname', '" "',
        # cache 'full': quem abre o mesmo arquivo ao mesmo tempo divide uma conexao so, e so fica no
        # PC o pedaco lido (abrir uma ISO nao baixa ela inteira). Passando de 2 GB, o mais velho sai.
        # 5 s antes de enviar: junta gravacoes seguidas do mesmo arquivo num envio so.
        '--vfs-cache-mode', 'full', '--vfs-cache-max-size', '2G', '--vfs-write-back', '5s',
        # um envio por vez
        '--transfers', '1',
        '--attr-timeout', '1s',
        # sem isso os arquivos aparecem sem permissao de executar, e o Explorer recusa abrir .bat/.exe
        # das unidades com "O Windows nao pode acessar o dispositivo..." (28/09)
        '--file-perms', '0777',
        '--contimeout', '10s', '--timeout', '60s', '--low-level-retries', '3',
        '--rc', '--rc-no-auth', '--rc-addr', "127.0.0.1:$($m.Porta)",
        '--no-console', '--log-level', 'NOTICE', '--log-file', "`"$log`"",
        # grava direto no nome final: sem arquivo .partial + renomear no cartao
        '--inplace'
    ) + $m.Extras -join ' '
    Start-Process -FilePath $rc -ArgumentList $argumentos -WindowStyle Hidden
}

# espera as duas montagens (ate 20 s)
for ($i = 0; $i -lt 40; $i++) {
    if (-not ($montagens | Where-Object { -not (Montada $_) })) { break }
    Start-Sleep -Milliseconds 500
}

$mapa = (subst.exe) -join "`n"
$faltou = @()
foreach ($l in $letras) {
    if ($mapa -match [regex]::Escape("$($l.Letra)\: => $($l.Alvo)")) { Write-Host "  $($l.Letra) ja estava conectado."; continue }
    if (Test-Path "$($l.Letra)\") { Write-Host "  $($l.Letra) esta em uso por outra coisa - pulando o $($l.Nome)."; $faltou += $l.Letra; continue }
    if (-not (Test-Path $l.Alvo)) { Write-Host "  O $($l.Nome) nao apareceu no FTP do PS2 - sem $($l.Letra)."; $faltou += $l.Letra; continue }
    # o nome da letra: so cria/usa a chave que e nossa (marcada com PS2rede), nunca mexe num nome que ja existia
    $chave = Join-Path $icones ($l.Letra.TrimEnd(':') + '\DefaultLabel')
    $nossa = -not (Test-Path $chave) -or ((Get-ItemProperty -Path (Split-Path $chave) -ErrorAction SilentlyContinue).PS2rede -eq 1)
    if ($nossa) {
        New-Item -Path $chave -Force | Out-Null
        Set-Item -Path $chave -Value $l.Rotulo
        New-ItemProperty -Path (Split-Path $chave) -Name 'PS2rede' -Value 1 -PropertyType DWord -Force | Out-Null
    }
    subst.exe $l.Letra $l.Alvo
}
if (-not (Test-Path 'P:\')) {
    Write-Host "  Nao consegui montar o P:. Detalhes em: $log"
    Fim 1
}

# a janelinha dos envios (uma so)
$monitor = Join-Path $aqui 'monitor.ps1'
$rodando = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*monitor.ps1*' }
if (-not $rodando) {
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$monitor`"" -WindowStyle Hidden
}

Write-Host ''
Write-Host '  Pronto!  P: = cartao do SD2PSX    M: = memory card em uso    H: = HD do PS2 (exFAT)'
if ($faltou) { Write-Host "  Ficou sem: $($faltou -join ' ')" }
Write-Host '  O Windows diz que a copia terminou antes de ela chegar no PS2: o que esta'
Write-Host '  subindo de verdade aparece na janelinha "PS2 - envios".'
Write-Host '  Antes de desligar o PS2 ou sair do FTP, rode "Desconectar PS2.bat".'
# (nao abre o Explorer sozinho: a pedido dele, 28/09)
Start-Sleep -Seconds 3
