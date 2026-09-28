//---------------------------------------------------------------------------
// File name:   receber.c
// wLaunchELF FTP: receive games sent from the PC.
//
// The PC script ("Mandar jogos pro PS2") serves the games with udpfsd and then, over FTP, drops a job
// file on the internal HDD. From the main menu this polls for that file, switches the network to udpfs
// (udpfs and the FTP server use different network drivers, so the FTP server stops), copies each game
// to ata0:/DVD or ata0:/CD through a staging folder, writes a result file and switches back to FTP,
// where the PC reads the result.
//
// Job file (ata0:/PS2-RECEBER.TXT), one game per line, fields separated by tabs:
//   PS2-RECEBER 1
//   DVD<tab>4132634624<tab>Burnout 2 - Point of Impact.iso
//   FIM
// Result file (ata0:/PS2-RECEBER.RES):
//   PS2-RECEBER-RES 1
//   <state><tab><bytes written><tab><seconds><tab><name>
//   FIM
//---------------------------------------------------------------------------
#include "launchelf.h"
#include "filer_shared.h"
#include "init.h"

#if defined(ETH) && defined(UDPFS) && defined(EXFAT)

#ifndef MC_ATTR_norm_file
#define MC_ATTR_norm_file 0x8497  //file (PS2/PS1) on PS2 MC
#endif

#define RECEBER_PEDIDO "ata0:/PS2-RECEBER.TXT"
#define RECEBER_RESULTADO "ata0:/PS2-RECEBER.RES"
#define RECEBER_PREPARO_DIR "ata0:/PS2-RECEBENDO"
#define RECEBER_PREPARO RECEBER_PREPARO_DIR "/"
#define RECEBER_MAX_ITENS 32
#define RECEBER_INTERVALO_MS 3000
#define RECEBER_BLOCO (256 * 1024)
#define RECEBER_RETOMADAS 8

typedef struct
{
	char pasta[4];  //"DVD" or "CD"
	u64 tamanho;
	char nome[MAX_NAME];
	const char *estado;
	u64 gravado;
	int segundos;
} ItemReceber;

static ItemReceber itens[RECEBER_MAX_ITENS];
static char pedido[8192];
static u8 bloco[RECEBER_BLOCO] __attribute__((aligned(64)));

//Returns 1 with a complete job, 0 when there is nothing (yet) and -1 for a job this build cannot use
static int lerPedido(int *n_itens)
{
	char *linha, *prox, *campo2, *campo3, *p;
	int fd, len, n = 0, fim = 0;

	fd = fileXioOpen(RECEBER_PEDIDO, FIO_O_RDONLY);
	if (fd < 0)
		return 0;
	len = fileXioRead(fd, pedido, sizeof(pedido) - 1);
	fileXioClose(fd);
	if (len <= 0)
		return 0;
	pedido[len] = '\0';

	if (strncmp(pedido, "PS2-RECEBER 1", 13))
		return -1;
	for (linha = strchr(pedido, '\n'); linha != NULL; linha = prox) {
		linha++;
		prox = strchr(linha, '\n');
		if (prox != NULL)
			*prox = '\0';
		if ((p = strchr(linha, '\r')) != NULL)
			*p = '\0';
		if (!strcmp(linha, "FIM")) {
			fim = 1;
			break;
		}
		if (linha[0] == '\0')
			continue;
		if ((campo2 = strchr(linha, '\t')) == NULL)
			return -1;
		*campo2++ = '\0';
		if ((campo3 = strchr(campo2, '\t')) == NULL)
			return -1;
		*campo3++ = '\0';
		if ((strcmp(linha, "DVD") && strcmp(linha, "CD")) || n >= RECEBER_MAX_ITENS ||
		    campo3[0] == '\0' || strlen(campo3) >= MAX_NAME || strchr(campo3, '/') || strchr(campo3, '\\'))
			return -1;
		strcpy(itens[n].pasta, linha);
		itens[n].tamanho = strtoull(campo2, NULL, 10);
		strcpy(itens[n].nome, campo3);
		n++;
	}
	if (!fim)
		return 0;  //still being written: read it again on the next poll
	*n_itens = n;
	return (n > 0) ? 1 : -1;
}

static void gravarResultado(int n)
{
	char linha[MAX_NAME + 64];
	int fd, i;

	fd = fileXioOpen(RECEBER_RESULTADO, FIO_O_WRONLY | FIO_O_CREAT | FIO_O_TRUNC, fileMode);
	if (fd < 0)
		return;
	strcpy(linha, "PS2-RECEBER-RES 1\n");
	fileXioWrite(fd, linha, strlen(linha));
	for (i = 0; i < n; i++) {
		snprintf(linha, sizeof(linha), "%s\t%llu\t%d\t%s\n", itens[i].estado,
		         (unsigned long long)itens[i].gravado, itens[i].segundos, itens[i].nome);
		fileXioWrite(fd, linha, strlen(linha));
	}
	strcpy(linha, "FIM\n");
	fileXioWrite(fd, linha, strlen(linha));
	fileXioClose(fd);
}

static u64 tamanhoDe(const char *caminho, int *existe)
{
	iox_stat_t st;

	*existe = (fileXioGetStat(caminho, &st) >= 0);
	return *existe ? (((u64)st.hisize << 32) | st.size) : 0;
}

static void desenharProgresso(const ItemReceber *it, int i, int n, u64 pos, u64 inicio, int retomadas)
{
	char texto[MAX_PATH];
	u64 ms = Timer() - inicio;
	unsigned int kbs = ms ? (unsigned int)((pos / 1024) * 1000 / ms) : 0;
	unsigned int falta = kbs ? (unsigned int)(((it->tamanho - pos) / 1024) / kbs) : 0;

	snprintf(texto, sizeof(texto), "Recebendo %d/%d: %.28s  %u%%  %u/%u MB  %u KB/s  faltam %u min%s",
	         i + 1, n, it->nome, (unsigned int)(it->tamanho ? pos * 100 / it->tamanho : 0),
	         (unsigned int)(pos >> 20), (unsigned int)(it->tamanho >> 20), kbs, (falta + 59) / 60,
	         retomadas ? "  (retomada)" : "");
	drawMsg(texto);
}

//Copies one game from udpfs to the HDD. When the udpfs server gives up on the PS2 (it does after about a
//second without acknowledgements, and the IOP stalls that long now and then while writing to the HDD), the
//udpfs client stays disconnected for good: reload the udpfs stack (an IOP reset) and resume where it
//stopped. Returns 0 when the whole file arrived, 1 when cancelled and -1 on failure.
static int copiarComRetomada(ItemReceber *it, const char *origem, const char *destino, int i, int n)
{
	static char zero = 0;
	int in = -1, out, lidos, pedir, retomadas = 0;
	u64 pos = 0, inicio = Timer(), ultimo = 0;

	out = fileXioOpen(destino, FIO_O_WRONLY | FIO_O_CREAT | FIO_O_TRUNC, fileMode);
	if (out < 0)
		return -1;
	//reserve the whole size before the transfer, so no cluster allocation happens in the middle of it
	//(harmless if the filesystem does not grow a file on a seek past the end)
	if (it->tamanho > 0) {
		drawMsg("Recebendo jogos do PC: reservando espaco no HD...");
		if (fileXioLseek64(out, (s64)it->tamanho - 1, SEEK_SET) == (s64)it->tamanho - 1)
			fileXioWrite(out, &zero, 1);
		fileXioLseek64(out, 0, SEEK_SET);
	}

	while (pos < it->tamanho) {
		if (in < 0) {
			in = fileXioOpen(origem, FIO_O_RDONLY);
			if (in >= 0 && pos > 0 && fileXioLseek64(in, (s64)pos, SEEK_SET) != (s64)pos) {
				fileXioClose(in);
				in = -1;
			}
		}
		pedir = (it->tamanho - pos > RECEBER_BLOCO) ? RECEBER_BLOCO : (int)(it->tamanho - pos);
		lidos = (in >= 0) ? fileXioRead(in, bloco, pedir) : -1;
		if (lidos <= 0) {
			if (in >= 0)
				fileXioClose(in);
			in = -1;
			fileXioClose(out);
			if (++retomadas > RECEBER_RETOMADAS) {
				it->gravado = pos;
				return -1;
			}
			{
				char texto[MAX_PATH];
				snprintf(texto, sizeof(texto), "Conexao com o PC caiu em %u MB: reconectando (%d de %d)...",
				         (unsigned int)(pos >> 20), retomadas, RECEBER_RETOMADAS);
				drawMsg(texto);
			}
			reloadUdpfsModules();
			loadAtaModules();
			out = fileXioOpen(destino, FIO_O_WRONLY);
			if (out < 0 || fileXioLseek64(out, (s64)pos, SEEK_SET) != (s64)pos) {
				if (out >= 0)
					fileXioClose(out);
				it->gravado = pos;
				return -1;
			}
			continue;
		}
		if (fileXioWrite(out, bloco, lidos) != lidos) {  //e.g. the HDD is full
			fileXioClose(in);
			fileXioClose(out);
			it->gravado = pos;
			return -1;
		}
		pos += lidos;

		if (Timer() - ultimo >= 500) {
			ultimo = Timer();
			desenharProgresso(it, i, n, pos, inicio, retomadas);
			if (readpad_noRepeat() && (new_pad & PAD_TRIANGLE) &&
			    ynDialog("Cancelar o recebimento deste jogo?") > 0) {
				fileXioClose(in);
				fileXioClose(out);
				it->gravado = pos;
				return 1;
			}
		}
	}
	if (in >= 0)
		fileXioClose(in);
	fileXioClose(out);
	it->gravado = pos;
	return 0;
}

static void receberJogos(char *msg)
{
	char destino[MAX_PATH], preparo[MAX_PATH], pasta[MAX_PATH], texto[MAX_PATH], origem[MAX_PATH];
	u64 inicio;
	int n = 0, i, r, dd, existe, servidor = 0, parar = 0, recebidos = 0;

	r = lerPedido(&n);
	if (r == 0)
		return;
	//taking the job away tells the PC it was picked up, and a job is never run twice
	fileXioRemove(RECEBER_PEDIDO);
	if (r < 0) {
		snprintf(msg, MAX_PATH, "Pedido do PC invalido (feito para outra versao?)");
		return;
	}

	for (i = 0; i < n; i++) {
		itens[i].estado = "NAO_FEITO";
		itens[i].gravado = 0;
		itens[i].segundos = 0;
	}

	drawMsg("Recebendo jogos do PC: trocando a rede para o udpfs (o FTP desliga)...");
	if (prepareTransferDeviceStacks("udpfs:/", RECEBER_PREPARO) == TRANSFER_STACK_READY) {
		//the PC starts its udpfs server before sending the job
		for (i = 0; i < 5 && !servidor; i++) {
			if ((dd = fileXioDopen("udpfs:/")) >= 0) {
				fileXioDclose(dd);
				servidor = 1;
			} else
				DelayThread(2000000);
		}
	}

	if (!servidor) {
		for (i = 0; i < n; i++)
			itens[i].estado = "SEM_SERVIDOR";
	} else {
		fileXioMkdir(RECEBER_PREPARO_DIR, fileMode);  //fails harmlessly when it already exists
		for (i = 0; i < n && !parar; i++) {
			snprintf(destino, sizeof(destino), "ata0:/%.3s/%.255s", itens[i].pasta, itens[i].nome);
			tamanhoDe(destino, &existe);
			if (existe) {  //never overwrite a game that is already on the HDD
				itens[i].estado = "JA_EXISTIA";
				continue;
			}
			snprintf(texto, sizeof(texto), "Recebendo %d de %d (%.3s): %.255s", i + 1, n, itens[i].pasta, itens[i].nome);
			drawMsg(texto);

			snprintf(preparo, sizeof(preparo), "%s%.255s", RECEBER_PREPARO, itens[i].nome);
			snprintf(origem, sizeof(origem), "udpfs:/%.255s", itens[i].nome);
			inicio = Timer();
			r = copiarComRetomada(&itens[i], origem, preparo, i, n);
			itens[i].segundos = (int)((Timer() - inicio) / 1000);

			//a game only lands in DVD or CD once it is complete, so OPL never lists half a copy
			//(the staged file already has its full size from the reservation, so trust r and the byte count)
			tamanhoDe(preparo, &existe);
			if (r == 0 && existe && itens[i].gravado == itens[i].tamanho) {
				snprintf(pasta, sizeof(pasta), "ata0:/%.3s", itens[i].pasta);
				fileXioMkdir(pasta, fileMode);
				if (fileXioRename(preparo, destino) >= 0) {
					itens[i].estado = "OK";
					recebidos++;
				} else
					itens[i].estado = "FICOU_EM_PS2-RECEBENDO";
			} else {
				if (existe)
					fileXioRemove(preparo);
				itens[i].estado = (r == 1) ? "CANCELADO" : "FALHOU";
				parar = 1;  //a failed or cancelled copy stops the rest
			}
		}
		fileXioRmdir(RECEBER_PREPARO_DIR);  //only goes away when empty
	}
	gravarResultado(n);

	//back to the FTP server (another IOP reset), then the storage it exposes, as at startup
	drawMsg("Recebendo jogos do PC: voltando para o FTP...");
	loadNetModules();
#ifdef MMCE
	loadMmceModules();
#endif
	loadAtaModules();

	if (!servidor)
		snprintf(msg, MAX_PATH, "Envio do PC: servidor udpfs nao encontrado");
	else
		snprintf(msg, MAX_PATH, "Recebidos do PC: %d de %d jogo(s)", recebidos, n);
}

//Called from the main menu loop: every few seconds, look for a job from the PC
void receberVerificar(char *msg, int *event)
{
	static u64 proxima = 0;
	iox_stat_t st;

	if (Timer() < proxima)
		return;
	proxima = Timer() + RECEBER_INTERVALO_MS;
	if (fileXioGetStat(RECEBER_PEDIDO, &st) < 0)
		return;
	receberJogos(msg);
	proxima = Timer() + RECEBER_INTERVALO_MS;
	*event |= 1;
}

#endif
//---------------------------------------------------------------------------
// End of file: receber.c
//---------------------------------------------------------------------------
