/* OctoLogin test harness: reproduces WoW.exe's Winsock import slots at the same addresses. */
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
typedef int (WINAPI *connect_t)(SOCKET, const struct sockaddr *, int);
static int fails, total;
#define CHECK(c, msg) do { total++; if (c) printf("  ok    %s\n", msg); else { fails++; printf("  FAIL  %s\n", msg); } } while (0)
__attribute__((section(".wowiat"), used)) void *wow_iat[0x400] = {(void *)1};
static void **slot = (void **)(uintptr_t)0x007FF6D0;

static int connect_via_slot(int port, int *peer_port, DWORD *ms)
{
	SOCKET s = socket(AF_INET, SOCK_STREAM, 0);
	struct sockaddr_in a = {0};
	a.sin_family = AF_INET; a.sin_port = htons((u_short)port); a.sin_addr.s_addr = inet_addr("127.0.0.1");
	DWORD t = GetTickCount();
	int r = ((connect_t)*slot)(s, (struct sockaddr *)&a, sizeof a);
	*ms = GetTickCount() - t;
	struct sockaddr_in p; int pl = sizeof p;
	*peer_port = (r == 0 && getpeername(s, (struct sockaddr *)&p, &pl) == 0) ? ntohs(p.sin_port) : -1;
	closesocket(s);
	return r;
}
static void ini(const char *k, const char *v) { WritePrivateProfileStringA("OctoLogin", k, v, ".\\OctoLogin.ini"); }

int main(int argc, char **argv)
{
	if (argc < 5) { printf("usage: harness dll silent good closed [login fast slow dead near]\n"); return 2; }
	int SILENT = atoi(argv[2]), GOOD = atoi(argv[3]), CLOSED = atoi(argv[4]);
	WSADATA w; WSAStartup(MAKEWORD(2, 2), &w);
	if ((uintptr_t)wow_iat != 0x007FF000) { printf("import slots are at the wrong address: %p\n", (void *)wow_iat); return 2; }
	FARPROC real = GetProcAddress(LoadLibraryA("wsock32.dll"), MAKEINTRESOURCEA(4));
	*slot = (void *)real;
	HMODULE wsk = LoadLibraryA("wsock32.dll");
	int ords[] = {19, 16, 18, 10, 3}; uintptr_t at[] = {0x7FF70C, 0x7FF714, 0x7FF708, 0x7FF718, 0x7FF704};
	for (int i = 0; i < 5; i++) *(void **)at[i] = (void *)GetProcAddress(wsk, MAKEINTRESOURCEA(ords[i]));
	DeleteFileA(".\\OctoLogin.ini"); DeleteFileA(".\\OctoLogin.log");
	char extra[200];
	/* the game always connects to port 3724; here the target is 127.0.0.1:3724 (refused at once)
	   and the candidates are the local test servers */
	snprintf(extra, sizeof extra, "127.0.0.1:3724,127.0.0.1:%d,127.0.0.1:%d,127.0.0.1:%d", SILENT, CLOSED, GOOD);
	ini("world", "0"); ini("hosts", ""); ini("extra", extra); ini("skiploopback", "0"); ini("budget_ms", "2000");
	HMODULE h = LoadLibraryA(argv[1]);
	CHECK(h != NULL, "DLL loaded");
	CHECK(*slot != (void *)real, "connect import slot points to the hook");
	int peer; DWORD ms;
	printf("== login: pick between a silent, a closed and a working server\n");
	connect_via_slot(3724, &peer, &ms);
	CHECK(peer == GOOD, "connected to the server that answered");
	CHECK(ms < 2000, "decided before the time budget ran out");
	char last[64]; GetPrivateProfileStringA("OctoLogin", "lastgood", "", last, sizeof last, ".\\OctoLogin.ini");
	char want[64]; snprintf(want, sizeof want, "127.0.0.1:%d", GOOD);
	CHECK(!strcmp(last, want), "last good address saved");
	printf("== non-OctoWoW address\n");
	ini("extra", "127.0.0.1:1"); 
	{   /* target not in the list: left alone (goes to the closed port and fails) */
		SOCKET s = socket(AF_INET, SOCK_STREAM, 0); struct sockaddr_in a = {0};
		a.sin_family = AF_INET; a.sin_port = htons(3724); a.sin_addr.s_addr = inet_addr("127.0.0.1");
		DWORD t = GetTickCount(); int r = ((connect_t)*slot)(s, (struct sockaddr *)&a, sizeof a); closesocket(s);
		CHECK(r != 0 && GetTickCount() - t < 1500, "unknown server left alone");
	}
	printf("== port other than 3724\n");
	ini("extra", extra);
	connect_via_slot(GOOD, &peer, &ms);
	CHECK(peer == GOOD && ms < 300, "other ports connect directly (no probing)");
	printf("== nothing answers\n");
	char dead[100]; snprintf(dead, sizeof dead, "127.0.0.1:3724,127.0.0.1:%d,127.0.0.1:%d", SILENT, CLOSED);
	ini("extra", dead); ini("lastgood", "");
	connect_via_slot(3724, &peer, &ms);
	CHECK(peer == SILENT, "without a login service, the address whose TCP opened is used");
	CHECK(ms >= 1900 && ms < 2600, "waited for the budget, not longer");
	printf("== can be turned off\n");
	ini("extra", extra); ini("enabled", "0");
	connect_via_slot(3724, &peer, &ms);
	CHECK(peer == -1 && ms < 1500, "enabled=0 uses the game's address");
	printf("== local proxy\n");
	ini("enabled", "1"); ini("skiploopback", "1");
	connect_via_slot(3724, &peer, &ms);
	{ char log[4096] = ""; FILE *f = fopen("OctoLogin.log", "r"); if (f) { size_t k = fread(log, 1, sizeof log - 1, f); log[k] = 0; fclose(f); }
	  CHECK(peer == -1 && strstr(log, "local proxy, left alone") != NULL, "a 127.x target (octoproxy) is left alone"); }

	printf("== world server (realm list)\n");
	if (argc < 10) { printf("  skipped (no world server ports)\n"); goto end; }
	{
		int LSRV = atoi(argv[5]), WFAST = atoi(argv[6]), WSLOW = atoi(argv[7]), WDEAD = atoi(argv[8]), WNEAR = atoi(argv[9]);
		typedef int (WINAPI *send_t)(SOCKET, const char *, int, int);
		typedef int (WINAPI *recv_t)(SOCKET, char *, int, int);
		typedef int (WINAPI *select_t)(int, fd_set *, fd_set *, fd_set *, const struct timeval *);
		typedef int (WINAPI *close_t)(SOCKET);
		CHECK(*(void **)0x7FF714 != (void *)GetProcAddress(wsk, MAKEINTRESOURCEA(16)), "recv import slot points to the hook");
		char ex[160], wh[260];
		snprintf(ex, sizeof ex, "127.0.0.1:3724,127.0.0.1:%d", LSRV);
		snprintf(wh, sizeof wh, "127.0.0.1:%d,127.0.0.1:%d,127.0.0.1:%d,127.0.0.1:%d", WFAST, WSLOW, WDEAD, WNEAR);
		ini("extra", ex); ini("skiploopback", "0"); ini("enabled", "1"); ini("lastgood", "");
		ini("world", "1"); ini("test_any_port", "1"); ini("world_hosts", wh); ini("worlds", ""); ini("world_window_ms", "1500"); ini("world_rate_ms", "100"); ini("world_timeout_ms", "500");
		SOCKET s = socket(AF_INET, SOCK_STREAM, 0);
		struct sockaddr_in a = {0}; a.sin_family = AF_INET; a.sin_port = htons(3724); a.sin_addr.s_addr = inet_addr("127.0.0.1");
		int r = ((connect_t)*slot)(s, (struct sockaddr *)&a, sizeof a);
		CHECK(r == 0, "connected to the login server");
		u_long nb = 1; ioctlsocket(s, FIONBIO, &nb);
		DWORD t0 = GetTickCount();
		const char req[5] = {0x10, 0, 0, 0, 0};
		((send_t)*(void **)0x7FF70C)(s, req, 5, 0);
		unsigned char got[2048]; int glen = 0, want = -1, maxsel = 0;
		while (GetTickCount() - t0 < 6000) {
			fd_set rd; FD_ZERO(&rd); FD_SET(s, &rd);
			struct timeval tv = {0, 200000};
			DWORD ts = GetTickCount();
			int k = ((select_t)*(void **)0x7FF708)(0, &rd, NULL, NULL, &tv);
			if ((int)(GetTickCount() - ts) > maxsel) maxsel = (int)(GetTickCount() - ts);
			if (k <= 0 || !FD_ISSET(s, &rd)) continue;
			int chunk = glen < 3 ? 3 - glen : 17;   /* small reads: the header first, then 17 bytes at a time */
			int n = ((recv_t)*(void **)0x7FF714)(s, (char *)got + glen, chunk, 0);
			if (n > 0) glen += n;
			if (glen >= 3 && want < 0) want = 3 + (got[1] | got[2] << 8);
			if (want > 0 && glen >= want) break;
		}
		DWORD took = GetTickCount() - t0;
		CHECK(want > 0 && glen == want, "realm list received in full");
		CHECK(took >= 1300 && took < 3500, "held until probing finished, then delivered");
		CHECK(maxsel <= 300, "select did not freeze the game while holding");
		/* decode the realm address fields */
		char addr[3][64] = {"", "", ""}; int i = 3 + 4 + 1;
		for (int rr = 0; rr < 3 && i < glen; rr++) {
			i += 5; i += (int)strlen((char *)got + i) + 1;
			snprintf(addr[rr], 64, "%s", (char *)got + i); i += (int)strlen((char *)got + i) + 1; i += 7;
		}
		char e0[64], e1[64], e2[64];
		snprintf(e0, 64, "127.0.0.1:%d", WFAST); snprintf(e1, 64, "127.0.0.1:%d", WFAST); snprintf(e2, 64, "127.0.0.1:%d", WNEAR);
		printf("    realm addresses: %s | %s | %s  (fast %d, slow %d, dead %d, near %d)\n", addr[0], addr[1], addr[2], WFAST, WSLOW, WDEAD, WNEAR);
		CHECK(!strcmp(addr[0], e0), "a dead server is replaced with the fast one");
		CHECK(!strcmp(addr[1], e1), "a slow server (>20 ms behind) is replaced with the fast one");
		CHECK(!strcmp(addr[2], e2), "OctoWoW's own pick is kept (no loss, within 20 ms)");
		CHECK(i == glen - 2, "packet layout and the 2-byte footer are preserved");
		char seen[512]; GetPrivateProfileStringA("OctoLogin", "worlds", "", seen, sizeof seen, ".\\OctoLogin.ini");
		char wd[64]; snprintf(wd, 64, "127.0.0.1:%d", WDEAD);
		CHECK(strstr(seen, wd) != NULL, "offered addresses are remembered for later logins");
		((close_t)*(void **)0x7FF704)(s);
	}
end:
	printf("\n%d/%d tests passed\n", total - fails, total);
	return fails != 0;
}
