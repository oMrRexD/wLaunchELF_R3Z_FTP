[English](README.md) | **Português**

# wLaunchELF R3Z FTP

Uma compilação do [wLaunchELF_R3Z](https://github.com/saildot4k/wLaunchELF_R3Z) v4.78 com o servidor FTP ligado, e
algumas ferramentas de Windows que usam ele. Com isso eu mexo no PS2 pelo PC, pela rede, sem tirar o microSD do
SD2PSX nem o HD interno do console: o cartão e o HD aparecem como unidades no Windows, o PC manda jogos pro HD, e
dá pra mandar o PS2 abrir um app, voltar pro menu ou desligar.

É um projeto pessoal, testado em um console só: SD2PSX (MMCE) como memory card, HD interno com partição exFAT,
OSDMenu e OPL. Está aqui do jeito que está, caso ajude alguém.

O README original do wLaunchELF_R3Z está na raiz do repositório ([README.md](../README.md)). O ramo com estas
mudanças é o `ftp`; o `master` é o do upstream, sem mexer.

## O que muda em relação ao R3Z oficial

- **Servidor FTP embutido e ligando sozinho.** As versões oficiais são compiladas com `ETH=0`, então não têm FTP.
  Esta liga a rede e o FTP assim que abre, e mostra o IP na tela. O IP vem do `IPCONFIG.DAT` ao lado do ELF (ou de
  `mc?:/SYS-CONF/IPCONFIG.DAT`), numa linha: `IP máscara gateway`.
- **Drivers de rede do ps2sdk v1.0 (2021).** Com o `ps2dev9`/`ps2ip` atuais, o adaptador de rede do meu console
  nunca subia. Os dois `.irx` estão em `iop/__v10/`, tirados da imagem oficial `ps2dev/ps2dev:v1.0`
  (SHA-256 `962bedf3…` e `9489a007…`).
- **SD2PSX e HD na raiz do FTP.** O `mmceman` e o driver do exFAT do HD são carregados na abertura:

  | Caminho no FTP | O que é |
  |---|---|
  | `/mmce/0/` | o cartão do SD2PSX |
  | `/mc/0/` | o memory card em uso (saves, SYS-CONF) |
  | `/ata/0/` | a partição exFAT do HD interno |
  | `/usb/0/` | pendrive |

- **Correções no ps2ftpd:** lista de dispositivos lida do iomanX (assim o `mmce` e os dispositivos BDM aparecem);
  só fecha arquivo que foi aberto de fato (era isso que travava o SD2PSX); a conexão de dados não repete comando
  velho; fim de arquivo nas leituras do `mmce`; buffer de 32 KB; `REST` acima de 2 GB (retomar e ler pedaços de
  ISO grande).
- **Receber jogos do PC pelo udpfs.** O PC serve uma pasta com o [udpfsd](https://github.com/pcm720/udpfsd) e
  deixa um pedido em `ata0:/PS2-RECEBER.TXT`; o PS2 puxa as ISOs e grava em `ata0:/DVD/` ou `ata0:/CD/`. Ele
  reserva o espaço antes e, se a conexão cair, reinicia a parte de rede e continua do mesmo byte (até 8 vezes por
  jogo). O jogo só aparece em `DVD`/`CD` depois de chegar inteiro (até lá fica em `ata0:/PS2-RECEBENDO/`), então
  o OPL nunca vê jogo pela metade. O triângulo pergunta se quer cancelar. O resultado vai pra
  `ata0:/PS2-RECEBER.RES`.
- **Comandos vindos do PC.** Um pedido em `ata0:/PS2-COMANDO.TXT` abre um ELF, volta pro menu do sistema
  (`MISC/OSDSYS`) ou desliga o PS2 (`MISC/PS2PowerOff`, que fecha o HD antes).
- **Mensagens no idioma do LaunchELF.** As mensagens na tela do receber jogos e dos comandos seguem o idioma
  escolhido no LaunchELF: inglês por padrão, português quando ele está em português.
- **Compilado sem DS34.** A variante DS34 do R3Z (DualShock 3/4 pela USB) tem um bug em que o X fica se repetindo
  no FileBrowser e o controle para de responder; acontece no R3Z-DS34 original também.

Receber jogos e os comandos precisam do HD interno com partição exFAT (`ata0`), porque os arquivos de pedido ficam
lá. O PS2 só confere (a cada 3 s) enquanto o app está no **menu principal**, não dentro do FileBrowser.

## Instalar no PS2

1. Baixe o zip da página de [Releases](https://github.com/oMrRexD/wLaunchELF_R3Z_FTP/releases).
2. Copie a pasta `APPS/wLaunchELF-FTP/` pro memory card, pro cartão do SD2PSX ou pro pendrive.
3. Edite o `IPCONFIG.DAT` com o IP que o PS2 vai ter na sua rede (sem ele, o IP é `192.168.0.10`).
4. Abra o `WLE-FTP.ELF`. O `title.cfg` faz ele aparecer na lista de apps do OPL como "wLaunchELF FTP".

Qualquer programa de FTP também serve (FileZilla, WinSCP): login anônimo, modo passivo e **uma conexão só** (ver
os limites mais abaixo).

## Ferramentas de Windows (`windows/pt-BR/`)

Feitas em PowerShell 5.1 (já vem no Windows 10/11). As mesmas ferramentas em inglês estão em `windows/en/`.

Programas que não estão neste repositório; baixe e coloque no lugar:

| Programa | Versão testada | Onde vai |
|---|---|---|
| [rclone](https://rclone.org/downloads/) | v1.75.1, windows-amd64 | `windows/pt-BR/Unidade do PS2/rclone.exe` |
| [WinFsp](https://winfsp.dev/rel/) | 2.1.25156 | instalar (é ele que cria as unidades) |
| [udpfsd](https://github.com/pcm720/udpfsd/releases) | v0.1.7, windows-amd64 | `windows/pt-BR/udpfsd/udpfsd.exe` |

Configurações que são do meu setup e precisam ser trocadas:

- o IP do PS2 (`192.168.1.111`), na linha `$ps2 = ...` de `Unidade do PS2/conectar.ps1`,
  `Unidade do PS2/desconectar.ps1`, `Mandar jogos pro PS2/mandar-jogos.ps1` e `Comandar PS2/comandar.ps1`;
- o tamanho da partição exFAT do HD (`444G`), no `conectar.ps1`; ele serve pra mostrar o espaço livre certo no `H:`.

### Unidade do PS2 (o PS2 como unidades do Windows)

O `Conectar PS2.bat` monta o FTP como três unidades:

- `P:` o cartão do SD2PSX
- `M:` o memory card em uso
- `H:` a partição exFAT do HD

Dá pra copiar, editar, apagar e até rodar `.bat` direto delas. O `Desconectar PS2.bat` desmonta.

- O Windows diz que a cópia terminou assim que o arquivo chega no cache do PC; o envio de verdade pro PS2 acontece
  depois. Uma janelinha, "PS2 - envios", mostra o que está subindo de verdade (arquivo, porcentagem, velocidade).
  Enquanto ela estiver vermelha, não feche o LaunchELF nem desligue o PS2. O `Desconectar` espera os envios
  terminarem.
- Cada montagem usa **uma** conexão. O SD2PSX não aguenta duas operações ao mesmo tempo (listar uma pasta no meio
  de uma gravação derrubou a gravação), e a rede do PS2 aceita só 5 conexões TCP no total.
- Espaço livre: o FTP não informa. No `H:` ele é calculado (tamanho da partição menos os arquivos); `P:` e `M:`
  mostram 1 PB, que é falso mas nunca faz o Windows recusar uma cópia.

### Mandar jogos pro PS2 (mandar jogos pro HD)

Arraste as ISOs (ou a pasta delas) pra cima do `Mandar jogos pro PS2.bat`, com o LaunchELF no menu principal. O
script serve a pasta com o udpfsd, deixa o pedido pelo FTP e acompanha a cópia; no fim mostra o resultado. CD ou
DVD é decidido pelo conteúdo da ISO (jogo de DVD tem UDF). Jogo que já está no HD é pulado, nunca sobrescrito. Só
`.iso`, e nome sem acento. O `Simular (sem PS2).bat` mostra o que seria mandado, e pra onde, sem tocar no PS2.

### Comandar PS2 (comandos remotos)

O `Comandar PS2.bat` mostra os apps da tela inicial do OSDMenu (lidos de `mc0:/SYS-CONF/OSDMENU.CNF`), mais as
opções de voltar pro menu, desligar ou digitar um caminho qualquer. Antes de mandar, ele confere pelo FTP se o ELF
existe. Sem menu, pra atalhos: `Comandar PS2.bat MENU`, `Comandar PS2.bat DESLIGAR` ou
`Comandar PS2.bat mmce0:/APPS/OPNPS2LD.ELF`. Depois que o PS2 abre outro app, ele sai da rede até o LaunchELF ser
aberto de novo.

O PC e o PS2 conversam por alguns arquivos na raiz do HD (`PS2-RECEBER.TXT`, `PS2-RECEBER.RES`,
`PS2-COMANDO.TXT`) e uma pasta de preparo (`PS2-RECEBENDO`). Eles são apagados depois do uso, e só aparecem se algo
der errado no meio do caminho.

## Velocidades e limites

Medido com o adaptador de rede de 100 Mbit do PS2 e o PC no Wi-Fi:

| | Velocidade |
|---|---|
| Cartão do SD2PSX pelo FTP | ~570 KB/s lendo, ~400 KB/s gravando |
| HD pelo FTP | ~1,1 MB/s lendo, ~1,2 MB/s gravando |
| Jogos pro HD pelo udpfs | ~2,8 a 3,4 MB/s (uma ISO de DVD de 4 GB leva ~24 min) |

Ótimo pra config, save, capa, cheat e app. Pra muitas ISOs grandes, o leitor USB (ou o HD ligado no PC) ainda é
mais rápido.

- Não grave nos `.mcd` do cartão do SD2PSX pelo `P:` com o PS2 ligado: o cartão em uso está aberto pelo SD2PSX.
  Save e config vão pelo `M:`, que passa pelo próprio PS2.
- Não abra o `mx4sio:/` no LaunchELF com o FTP ligado: o R3Z reinicia o IOP pra trocar de driver e o FTP cai.
- Abrir o `udpfs:/` no FileBrowser também reinicia a parte de rede, e o FTP cai (normal).
- Os horários dos arquivos aparecem em UTC.
- O receber jogos já passou por um engasgo do HD, mas a retomada depois de uma queda de conexão de verdade ainda não
  foi testada.

## Compilar

O ELF da release foi compilado com a imagem oficial da toolchain fixada em
`ps2dev/ps2dev@sha256:8fba50ecc2229acd7f8da63d34302f12939b7d4fa6848dda1e6a0ce083321a11` (GCC 15.2), com:

```sh
git clean -xfd iop/ds34usb iop/ds34bt
make rebuild ETH=1 UDPFS=1 EXFAT=1 MMCE=1 MX4SIO=1 LCDVD=LATEST DVRP=1 XFROM=1 DS34=0
```

O `make rebuild` não limpa o `iop/ds34usb` e o `iop/ds34bt`; com sobra lá dentro, o make pula a etapa e embute um
módulo vazio. O `git clean` é pra isso.

## Créditos

- wLaunchELF / uLaunchELF: [ps2homebrew/wLaunchELF](https://github.com/ps2homebrew/wLaunchELF) e todos os autores
- [wLaunchELF_ISR](https://github.com/israpps/wLaunchELF_ISR), do israpps
- [wLaunchELF_R3Z](https://github.com/saildot4k/wLaunchELF_R3Z), do R3Z3N (saildot4k)
- ps2ftpd, do código do wLaunchELF
- [udpfsd](https://github.com/pcm720/udpfsd), do pcm720
- [ps2sdk](https://github.com/ps2dev/ps2sdk), [rclone](https://rclone.org) e [WinFsp](https://winfsp.dev)

Mudanças deste fork: MrRexD.
