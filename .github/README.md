**English** | [Português](README.pt-BR.md)

# wLaunchELF R3Z FTP

A build of [wLaunchELF_R3Z](https://github.com/saildot4k/wLaunchELF_R3Z) v4.78 with the FTP server turned on, and a few
Windows tools that use it. With it I manage the PS2 from the PC over the network, without taking the SD2PSX microSD
or the internal HDD out of the console: the card and the HDD show up as drive letters in Windows, the PC can send
games to the HDD, and it can tell the PS2 to open an app, go back to the menu or power off.

It is a personal project, tested on one console only: SD2PSX (MMCE) as the memory card, internal HDD with an exFAT
partition, OSDMenu and OPL. It is shared as-is, in case it helps someone.

The original wLaunchELF_R3Z README is at the root of the repository ([README.md](../README.md)). The branch with
these changes is `ftp`; `master` is the upstream branch, untouched.

## What changes from the official R3Z

- **FTP server built in and started automatically.** The official builds are compiled with `ETH=0`, so they have no
  FTP. This one starts the network and the FTP server as soon as it opens, and shows the IP on screen. The IP comes
  from `IPCONFIG.DAT` next to the ELF (or `mc?:/SYS-CONF/IPCONFIG.DAT`), one line: `IP netmask gateway`.
- **Network drivers from ps2sdk v1.0 (2021).** With the current `ps2dev9`/`ps2ip`, the network adapter of my console
  never came up. The two `.irx` files are in `iop/__v10/`, taken from the official `ps2dev/ps2dev:v1.0` image
  (SHA-256 `962bedf3…` and `9489a007…`).
- **SD2PSX and HDD on the FTP root.** `mmceman` and the HDD exFAT driver are loaded at startup:

  | FTP path | What it is |
  |---|---|
  | `/mmce/0/` | the SD2PSX card |
  | `/mc/0/` | the memory card in use (saves, SYS-CONF) |
  | `/ata/0/` | the exFAT partition of the internal HDD |
  | `/usb/0/` | USB drive |

- **ps2ftpd fixes:** device list read from iomanX (so `mmce` and the BDM devices appear); only close files that were
  actually opened (this used to hang the SD2PSX); the data connection no longer repeats an old command; end of file
  on `mmce` reads; 32 KB buffer; `REST` past 2 GB (resume and partial reads of big ISOs).
- **Receive games from the PC over udpfs.** The PC serves a folder with [udpfsd](https://github.com/pcm720/udpfsd) and
  leaves a request in `ata0:/PS2-RECEBER.TXT`; the PS2 pulls the ISOs and writes them to `ata0:/DVD/` or `ata0:/CD/`.
  It reserves the space first, and if the connection drops it restarts the network part and resumes from the same
  byte (up to 8 times per game). A game only appears in `DVD`/`CD` once it is complete (until then it stays in
  `ata0:/PS2-RECEBENDO/`), so OPL never sees half a game. Triangle asks whether to cancel. The result goes to
  `ata0:/PS2-RECEBER.RES`.
- **Commands from the PC.** A request in `ata0:/PS2-COMANDO.TXT` runs an ELF, goes back to the system menu
  (`MISC/OSDSYS`) or powers the PS2 off (`MISC/PS2PowerOff`, which closes the HDD first).
- **Messages in the LaunchELF language.** The on-screen messages of receiving games and of the commands follow the
  language set in the LaunchELF: English by default, Portuguese when it is set to Portuguese.
- **Built without DS34.** The DS34 variant of R3Z (DualShock 3/4 over USB) has a bug where X keeps repeating in the
  FileBrowser and the pad stops responding; it happens with the original R3Z-DS34 too.

Receiving games and commands need the internal HDD with an exFAT partition (`ata0`), because the request files live
there. The PS2 only checks them (every 3 s) while the app is on the **main menu**, not inside the FileBrowser.

## Installing on the PS2

1. Download the zip from the [Releases](https://github.com/oMrRexD/wLaunchELF_R3Z_FTP/releases) page.
2. Copy the folder `APPS/wLaunchELF-FTP/` to your memory card, SD2PSX card or USB drive.
3. Edit `IPCONFIG.DAT` with the IP you want for the PS2 on your network (without it, the IP is `192.168.0.10`).
4. Open `WLE-FTP.ELF`. The `title.cfg` makes it appear in OPL's app list as "wLaunchELF FTP".

Any FTP client works too (FileZilla, WinSCP): anonymous login, passive mode, and **one connection only** (see the
limits below).

## Windows tools (`windows/en/`)

Written in PowerShell 5.1 (comes with Windows 10/11). The same tools in Portuguese are in `windows/pt-BR/`.

Programs that are not in this repository; download them and put them in place:

| Program | Tested version | Where it goes |
|---|---|---|
| [rclone](https://rclone.org/downloads/) | v1.75.1, windows-amd64 | `windows/en/PS2 Drive/rclone.exe` |
| [WinFsp](https://winfsp.dev/rel/) | 2.1.25156 | install it (creates the drives) |
| [udpfsd](https://github.com/pcm720/udpfsd/releases) | v0.1.7, windows-amd64 | `windows/en/udpfsd/udpfsd.exe` |

Settings that are specific to my setup and need to be changed:

- the PS2 IP (`192.168.1.111`), in the `$ps2 = ...` line of `PS2 Drive/connect.ps1`, `PS2 Drive/disconnect.ps1`,
  `Send Games to PS2/send-games.ps1` and `Command PS2/command.ps1`;
- the size of the HDD exFAT partition (`444G`), in `connect.ps1`; it is used to show the real free space on `H:`.

### PS2 Drive (the PS2 as Windows drives)

`Connect PS2.bat` mounts the FTP as three drives:

- `P:` the SD2PSX card
- `M:` the memory card in use
- `H:` the HDD exFAT partition

You can copy, edit, delete and even run `.bat` files from them. `Disconnect PS2.bat` unmounts them.

- Windows reports a copy as finished as soon as the file reaches the cache on the PC; the real upload to the PS2
  happens afterwards. A small window, "PS2 - uploads", shows what is really being uploaded (file, percentage, speed).
  While it is red, do not close the LaunchELF or turn the PS2 off. `Disconnect` waits for the uploads to finish.
- Each mount uses **one** connection. The SD2PSX cannot handle two operations at the same time (listing a folder in
  the middle of a write broke the write), and the PS2 network stack accepts only 5 TCP connections in total.
- Free space: FTP does not report it. On `H:` it is calculated (partition size minus the files); `P:` and `M:` show
  1 PB, which is false but never makes Windows refuse a copy.

### Send Games to PS2 (send games to the HDD)

Drag ISOs (or their folder) onto `Send Games to PS2.bat`, with the LaunchELF on the main menu. The script serves
the folder with udpfsd, leaves the request over FTP and follows the copy; at the end it shows the result. CD or DVD
is decided by the ISO contents (DVD games have UDF). A game that is already on the HDD is skipped, never
overwritten. Only `.iso`, and names without accents. `Simulate (no PS2).bat` shows what would be sent, and where,
without touching the PS2.

### Command PS2 (remote commands)

`Command PS2.bat` shows the apps of the OSDMenu home screen (read from `mc0:/SYS-CONF/OSDMENU.CNF`), plus options
to go back to the menu, power off, or type any path. Before sending, it checks over FTP that the ELF exists.
Without the menu, for shortcuts: `Command PS2.bat MENU`, `Command PS2.bat POWEROFF` or
`Command PS2.bat mmce0:/APPS/OPNPS2LD.ELF`. After the PS2 opens another app it leaves the network until the
LaunchELF is opened again.

The PC and the PS2 talk through a few files on the HDD root (`PS2-RECEBER.TXT`, `PS2-RECEBER.RES`,
`PS2-COMANDO.TXT`) and a staging folder (`PS2-RECEBENDO`). Their names and keywords are Portuguese, from the first
version of the protocol; they are deleted after use, and you only see them if something goes wrong midway.

## Speeds and limits

Measured with the PS2's 100 Mbit adapter and the PC on Wi-Fi:

| | Speed |
|---|---|
| SD2PSX card over FTP | ~570 KB/s reading, ~400 KB/s writing |
| HDD over FTP | ~1.1 MB/s reading, ~1.2 MB/s writing |
| Games to the HDD over udpfs | ~2.8 to 3.4 MB/s (a 4 GB DVD ISO takes ~24 min) |

Good for configs, saves, covers, cheats and apps. For many big ISOs, a USB reader (or the HDD connected to the PC)
is still faster.

- Do not write the `.mcd` files of the SD2PSX card over `P:` while the PS2 is on: the card in use is open by the
  SD2PSX. Saves and configs go through `M:`, which passes through the PS2 itself.
- Do not open `mx4sio:/` in the LaunchELF with the FTP on: R3Z reboots the IOP to switch drivers and the FTP goes down.
- Opening `udpfs:/` in the FileBrowser also restarts the network part, and the FTP goes down (normal).
- File times show up in UTC.
- Receiving games has already survived a hiccup of the HDD, but the resume after a real connection drop has not been
  exercised yet.

## Building

The ELF in the release was built with the official toolchain image pinned at
`ps2dev/ps2dev@sha256:8fba50ecc2229acd7f8da63d34302f12939b7d4fa6848dda1e6a0ce083321a11` (GCC 15.2), with:

```sh
git clean -xfd iop/ds34usb iop/ds34bt
make rebuild ETH=1 UDPFS=1 EXFAT=1 MMCE=1 MX4SIO=1 LCDVD=LATEST DVRP=1 XFROM=1 DS34=0
```

`make rebuild` does not clean `iop/ds34usb` and `iop/ds34bt`; with leftovers in there, make skips the step and
embeds an empty module. That is what the `git clean` is for.

## Credits

- wLaunchELF / uLaunchELF: [ps2homebrew/wLaunchELF](https://github.com/ps2homebrew/wLaunchELF) and all its authors
- [wLaunchELF_ISR](https://github.com/israpps/wLaunchELF_ISR) by israpps
- [wLaunchELF_R3Z](https://github.com/saildot4k/wLaunchELF_R3Z) by R3Z3N (saildot4k)
- ps2ftpd, from the wLaunchELF source tree
- [udpfsd](https://github.com/pcm720/udpfsd) by pcm720
- [ps2sdk](https://github.com/ps2dev/ps2sdk), [rclone](https://rclone.org) and [WinFsp](https://winfsp.dev)

Changes in this fork by MrRexD.
