//---------------------------------------------------------------------------
// File name:   comando.c
// wLaunchELF FTP: commands sent from the PC.
//
// The PC drops ata0:/PS2-COMANDO.TXT over FTP. From the main menu this polls for it every few seconds,
// removes it (a command runs once) and hands it to the main menu's own launcher:
//   PS2-COMANDO 1
//   EXECUTAR<tab>mmce0:/APPS/OPNPS2LD.ELF   any path the main menu can launch
//   MENU                                    MISC/OSDSYS: back to the system menu (OSDMenu here)
//   DESLIGAR                                MISC/PS2PowerOff: closes the HDD and powers off
//   FIM
//---------------------------------------------------------------------------
#include "launchelf.h"

#if defined(ETH) && defined(EXFAT)

#define COMANDO_ARQUIVO "ata0:/PS2-COMANDO.TXT"
#define COMANDO_INTERVALO_MS 3000

void comandoVerificar(char *runpath, int tamanho, char *msg)
{
	static u64 proxima = 0;
	static char texto[1024];
	iox_stat_t st;
	char *linha, *p;
	int fd, len;

	if (Timer() < proxima)
		return;
	proxima = Timer() + COMANDO_INTERVALO_MS;
	if (fileXioGetStat(COMANDO_ARQUIVO, &st) < 0)
		return;

	fd = fileXioOpen(COMANDO_ARQUIVO, FIO_O_RDONLY);
	if (fd < 0)
		return;
	len = fileXioRead(fd, texto, sizeof(texto) - 1);
	fileXioClose(fd);
	if (len <= 0)
		return;
	texto[len] = '\0';
	if (!strstr(texto, "\nFIM"))
		return;  //still being written: read it again on the next poll
	fileXioRemove(COMANDO_ARQUIVO);

	if (strncmp(texto, "PS2-COMANDO 1", 13) || (linha = strchr(texto, '\n')) == NULL) {
		snprintf(msg, MAX_PATH, "%s", LNG(PC_Cmd_Bad));
		return;
	}
	linha++;
	if ((p = strchr(linha, '\n')) != NULL)
		*p = '\0';
	if ((p = strchr(linha, '\r')) != NULL)
		*p = '\0';

	if (!strncmp(linha, "EXECUTAR\t", 9) && linha[9] != '\0')
		snprintf(runpath, tamanho, "%s", linha + 9);
	else if (!strcmp(linha, "MENU"))
		snprintf(runpath, tamanho, "%s", setting->Misc_OSDSYS);
	else if (!strcmp(linha, "DESLIGAR"))
		snprintf(runpath, tamanho, "%s", setting->Misc_PS2PowerOff);
	else
		snprintf(msg, MAX_PATH, LNG(PC_Cmd_Unknown), linha);
}

#endif
//---------------------------------------------------------------------------
// End of file: comando.c
//---------------------------------------------------------------------------
