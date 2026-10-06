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

/* Connects through the hooked import slot like the game does. *answered: a logon challenge sent
 * over the connection got the fake login server's reply (00 00 04) within a second. */
static int connect_via_slot(int port, int *peer_port, DWORD *ms, int *answered)
{
	SOCKET s = socket(AF_INET, SOCK_STREAM, 0);
	struct sockaddr_in a = {0};
	a.sin_family = AF_INET; a.sin_port = htons((u_short)port); a.sin_addr.s_addr = inet_addr("127.0.0.1");
	DWORD t = GetTickCount();
	int r = ((connect_t)*slot)(s, (struct sockaddr *)&a, sizeof a);
	*ms = GetTickCount() - t;
	struct sockaddr_in p; int pl = sizeof p;
	*peer_port = (r == 0 && getpeername(s, (struct sockaddr *)&p, &pl) == 0) ? ntohs(p.sin_port) : -1;
	if (answered) {
		*answered = 0;
		const char chal[8] = {0x00, 0x03, 0x04, 0x00, 'T', 'E', 'S', 'T'};
		if (r == 0 && send(s, chal, sizeof chal, 0) == sizeof chal) {
			fd_set rd; FD_ZERO(&rd); FD_SET(s, &rd);
			struct timeval tv = {1, 0};
			unsigned char b[3]; int got = 0;
			while (got < 3 && select(0, &rd, NULL, NULL, &tv) == 1) {
				int k = recv(s, (char *)b + got, 3 - got, 0);
				if (k <= 0) break;
				got += k;
			}
			*answered = got == 3 && b[0] == 0 && b[1] == 0 && b[2] == 4;
		}
	}
	closesocket(s);
	return r;
}
static int is_server_port(int p, const int *ports, int n) { for (int i = 0; i < n; i++) if (p == ports[i]) return 1; return 0; }
static void read_log(char *log, size_t n) { log[0] = 0; FILE *f = fopen("OctoLogin.log", "r"); if (f) { size_t k = fread(log, 1, n - 1, f); log[k] = 0; fclose(f); } }
static void ini(const char *k, const char *v) { WritePrivateProfileStringA("OctoLogin", k, v, ".\\OctoLogin.ini"); }

/* connections the fake world servers accepted so far (run_tests.sh appends one byte each) */
static long world_connections(void)
{
	WIN32_FILE_ATTRIBUTE_DATA d;
	if (!GetFileAttributesExA("Z:\\tmp\\ol_wcount", GetFileExInfoStandard, &d))
		return 0;
	return (long)d.nFileSizeLow;
}

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
	{
		int untouched = 1;
		for (int i = 0; i < 5; i++) if (*(void **)at[i] != (void *)GetProcAddress(wsk, MAKEINTRESOURCEA(ords[i]))) untouched = 0;
		CHECK(untouched, "send/recv/select/ioctlsocket/closesocket import slots are untouched");
	}
	int peer, ans; DWORD ms;
	int servers[] = {SILENT, GOOD, CLOSED, 3724};
	printf("== login: pick between a silent, a closed and a working server\n");
	connect_via_slot(3724, &peer, &ms, &ans);
	CHECK(peer > 0 && !is_server_port(peer, servers, 4), "the game's connection goes to the local relay");
	CHECK(ans, "the relay carries the login to the server that answered");
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
	connect_via_slot(GOOD, &peer, &ms, NULL);
	CHECK(peer == GOOD && ms < 300, "other ports connect directly (no probing)");
	printf("== nothing answers\n");
	char dead[100]; snprintf(dead, sizeof dead, "127.0.0.1:3724,127.0.0.1:%d,127.0.0.1:%d", SILENT, CLOSED);
	ini("extra", dead); ini("lastgood", "");
	connect_via_slot(3724, &peer, &ms, NULL);
	{ char log[4096], want2[96]; read_log(log, sizeof log); snprintf(want2, sizeof want2, "using 127.0.0.1:%d (TCP open", SILENT);
	  CHECK(peer > 0 && !is_server_port(peer, servers, 4) && strstr(log, want2) != NULL, "without a login service, the address whose TCP opened is used (relayed)"); }
	CHECK(ms >= 1900 && ms < 2600, "waited for the budget, not longer");
	printf("== can be turned off\n");
	ini("extra", extra); ini("enabled", "0");
	connect_via_slot(3724, &peer, &ms, NULL);
	CHECK(peer == -1 && ms < 1500, "enabled=0 uses the game's address");
	printf("== local proxy\n");
	ini("enabled", "1"); ini("skiploopback", "1");
	connect_via_slot(3724, &peer, &ms, NULL);
	{ char log[4096]; read_log(log, sizeof log);
	  CHECK(peer == -1 && strstr(log, "local proxy, left alone") != NULL, "a 127.x target (octoproxy) is left alone"); }

	printf("== world server (realm list)\n");
	if (argc < 10) { printf("  skipped (no world server ports)\n"); goto end; }
	{
		int LSRV = atoi(argv[5]), WFAST = atoi(argv[6]), WSLOW = atoi(argv[7]), WDEAD = atoi(argv[8]), WNEAR = atoi(argv[9]);
		char ex[160], wh[260];
		snprintf(ex, sizeof ex, "127.0.0.1:3724,127.0.0.1:%d", LSRV);
		snprintf(wh, sizeof wh, "127.0.0.1:%d,127.0.0.1:%d,127.0.0.1:%d,127.0.0.1:%d", WFAST, WSLOW, WDEAD, WNEAR);
		ini("extra", ex); ini("skiploopback", "0"); ini("enabled", "1"); ini("lastgood", "");
		/* the built-in list holds real OctoWoW servers: tests must never reach them. Instead 9 local
		 * addresses that refuse at once, to check that more than 8 entries are all used. */
		ini("known_worlds", "127.0.0.2:1,127.0.0.2:2,127.0.0.2:3,127.0.0.2:4,127.0.0.2:5,127.0.0.2:6,127.0.0.2:7,127.0.0.2:8,127.0.0.2:9");
		ini("world", "1"); ini("test_any_port", "1"); ini("world_hosts", wh); ini("worlds", ""); ini("world_window_ms", "1500"); ini("world_rate_ms", "100"); ini("world_timeout_ms", "500");
		SOCKET s = socket(AF_INET, SOCK_STREAM, 0);
		struct sockaddr_in a = {0}; a.sin_family = AF_INET; a.sin_port = htons(3724); a.sin_addr.s_addr = inet_addr("127.0.0.1");
		int r = ((connect_t)*slot)(s, (struct sockaddr *)&a, sizeof a);
		CHECK(r == 0, "connected to the login server");
		Sleep(700); /* the client authenticates here */
		CHECK(world_connections() == 0, "no world server is contacted while the client authenticates");
		u_long nb = 1; ioctlsocket(s, FIONBIO, &nb);
		DWORD t0 = GetTickCount();
		const char req[5] = {0x10, 0, 0, 0, 0};
		send(s, req, 5, 0);
		unsigned char got[2048]; int glen = 0, want = -1, maxsel = 0;
		while (GetTickCount() - t0 < 6000) {
			fd_set rd; FD_ZERO(&rd); FD_SET(s, &rd);
			struct timeval tv = {0, 200000};
			DWORD ts = GetTickCount();
			int k = select(0, &rd, NULL, NULL, &tv);
			if ((int)(GetTickCount() - ts) > maxsel) maxsel = (int)(GetTickCount() - ts);
			if (k <= 0 || !FD_ISSET(s, &rd)) continue;
			int chunk = glen < 3 ? 3 - glen : 17;   /* small reads: the header first, then 17 bytes at a time */
			int n = recv(s, (char *)got + glen, chunk, 0);
			if (n > 0) glen += n;
			if (glen >= 3 && want < 0) want = 3 + (got[1] | got[2] << 8);
			if (want > 0 && glen >= want) break;
		}
		DWORD took = GetTickCount() - t0;
		CHECK(want > 0 && glen == want, "realm list received in full");
		/* the dead server's tests end by their 500 ms timeout; the window is 1500 ms */
		CHECK(took >= 500 && took < 1500 + 800, "held until every test finished (not longer than the window), then delivered");
		CHECK(world_connections() > 0, "world servers are tested once the client asks for the realm list");
		{ char log[8192]; read_log(log, sizeof log);
		  CHECK(strstr(log, "testing 13 known world servers") != NULL, "every listed world server is used (4 from DNS + 9 known, no 8-entry limit)");
		  CHECK(strstr(log, "92.114.107") == NULL, "no real OctoWoW server was contacted by the tests"); }
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
		{   /* the fake login server closes 1 s after the realm list: the game must see the close */
			nb = 0; ioctlsocket(s, FIONBIO, &nb);
			fd_set rd; FD_ZERO(&rd); FD_SET(s, &rd);
			struct timeval tv = {3, 0}; char b[16];
			int k = select(0, &rd, NULL, NULL, &tv) == 1 ? recv(s, b, sizeof b, 0) : -2;
			CHECK(k == 0, "when the login server closes, the game's connection closes too");
		}
		closesocket(s);
	}
end:
	printf("\n%d/%d tests passed\n", total - fails, total);
	return fails != 0;
}
