/* OctoLogin: makes the OctoWoW login connection reliable (WoW 1.12.1 / 5875).
 *
 * The game's connect() to the login server (port 3724) is intercepted. The known OctoWoW
 * login addresses (the realmlist address, every IP of play/normal.octowow.st, fallbacks
 * from OctoLogin.ini and the last address that worked) are tried at the same time, once
 * each: a TCP connection plus a real logon challenge (for an account name that does not
 * exist). The first address whose login service answers is handed to the game. If none
 * answers, the game's own address is used unchanged.
 *
 * It only acts when the target is one of the OctoWoW addresses; other servers, local
 * addresses (octoproxy) and ports other than 3724 are left alone.
 * To stay clear of the DDoS filter: one attempt per address per login, 8 addresses at most. */
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define OL_VERSION "1.0.0"
#define ADDR_IAT_CONNECT 0x007FF6D0u /* WoW.exe: WSOCK32 #4 (connect) */
#define LOGIN_PORT 3724
#define MAX_CAND 8

typedef int (WINAPI *connect_t)(SOCKET, const struct sockaddr *, int);
static connect_t g_realConnect;
static char g_dir[MAX_PATH];
static CRITICAL_SECTION g_logLock;

/* ---------------------------------------------------------------- log */
static void ollog(const char *fmt, ...)
{
	char path[MAX_PATH + 32], line[600];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(line, sizeof line, fmt, ap);
	va_end(ap);
	snprintf(path, sizeof path, "%sOctoLogin.log", g_dir);
	EnterCriticalSection(&g_logLock);
	FILE *f = fopen(path, "a");
	if (f) {
		SYSTEMTIME t;
		GetLocalTime(&t);
		fprintf(f, "%02d:%02d:%02d %s\n", t.wHour, t.wMinute, t.wSecond, line);
		fclose(f);
	}
	LeaveCriticalSection(&g_logLock);
}

static void ini_path(char *out, size_t n) { snprintf(out, n, "%sOctoLogin.ini", g_dir); }

/* ---------------------------------------------------------------- candidates */
typedef struct { struct sockaddr_in a; char why[24]; } Cand;

static int same(const struct sockaddr_in *x, const struct sockaddr_in *y)
{
	return x->sin_addr.s_addr == y->sin_addr.s_addr && x->sin_port == y->sin_port;
}

static int add_cand(Cand *c, int n, struct sockaddr_in a, const char *why)
{
	for (int i = 0; i < n; i++)
		if (same(&c[i].a, &a))
			return n;
	if (n >= MAX_CAND)
		return n;
	c[n].a = a;
	snprintf(c[n].why, sizeof c[n].why, "%s", why);
	return n + 1;
}

/* "host" or "host:port"; for a host name, every IP it resolves to */
static int add_spec(Cand *c, int n, const char *spec, const char *why)
{
	char host[128];
	int port = LOGIN_PORT;
	if (strlen(spec) >= sizeof host)
		return n;
	memcpy(host, spec, strlen(spec) + 1);
	char *colon = strchr(host, ':');
	if (colon) {
		*colon = 0;
		port = atoi(colon + 1);
	}
	while (*host == ' ')
		memmove(host, host + 1, strlen(host));
	for (char *e = host + strlen(host); e > host && (e[-1] == ' ' || e[-1] == '\r' || e[-1] == '\n'); )
		*--e = 0;
	if (!host[0] || port <= 0 || port > 65535)
		return n;
	struct sockaddr_in a = {0};
	a.sin_family = AF_INET;
	a.sin_port = htons((u_short)port);
	unsigned long ip = inet_addr(host);
	if (ip != INADDR_NONE) {
		a.sin_addr.s_addr = ip;
		return add_cand(c, n, a, why);
	}
	struct hostent *he = gethostbyname(host);
	if (!he || he->h_addrtype != AF_INET)
		return n;
	for (int i = 0; he->h_addr_list[i]; i++) {
		memcpy(&a.sin_addr, he->h_addr_list[i], 4);
		n = add_cand(c, n, a, why);
	}
	return n;
}

static int add_list(Cand *c, int n, const char *csv, const char *why)
{
	char buf[512];
	snprintf(buf, sizeof buf, "%s", csv);
	for (char *tok = buf; *tok; ) {
		char *end = tok + strcspn(tok, ",; ");
		char keep = *end;
		*end = 0;
		if (*tok)
			n = add_spec(c, n, tok, why);
		if (!keep)
			break;
		tok = end + 1;
	}
	return n;
}

static void ini_get(const char *key, const char *def, char *out, DWORD n)
{
	char ini[MAX_PATH + 32];
	ini_path(ini, sizeof ini);
	GetPrivateProfileStringA("OctoLogin", key, def, out, n, ini);
}

/* ---------------------------------------------------------------- login probe */
static const unsigned char *challenge(int *len)
{
	static unsigned char p[64];
	static int n;
	if (!n) {
		const char name[] = "OCTOLOGIN";
		unsigned char body[48];
		int b = 0;
		memcpy(body + b, "WoW", 4); b += 4;
		body[b++] = 1; body[b++] = 12; body[b++] = 1;
		body[b++] = 5875 & 0xFF; body[b++] = 5875 >> 8;
		memcpy(body + b, "68x", 4); b += 4;
		memcpy(body + b, "niW", 4); b += 4;
		memcpy(body + b, "SUne", 4); b += 4;
		memset(body + b, 0, 4); b += 4;                  /* timezone bias */
		body[b++] = 127; body[b++] = 0; body[b++] = 0; body[b++] = 1;
		body[b++] = (unsigned char)(sizeof name - 1);
		memcpy(body + b, name, sizeof name - 1); b += (int)sizeof name - 1;
		p[0] = 0x00; p[1] = 0x03; p[2] = (unsigned char)(b & 0xFF); p[3] = (unsigned char)(b >> 8);
		memcpy(p + 4, body, (size_t)b);
		n = b + 4;
	}
	*len = n;
	return p;
}

enum { ST_CONNECT, ST_WAIT, ST_DONE, ST_FAIL };
static const char *addr_str(const struct sockaddr_in *a, char *buf, size_t n);

/* Tries every candidate at once and returns the index of the first whose login service
 * answers. If none answers: -(i + 2) for the first one whose TCP connection opened, else -1. */
static int race(Cand *c, int n, DWORD budget_ms, DWORD *ms_out)
{
	SOCKET s[MAX_CAND];
	int st[MAX_CAND], tcp_first = -1, winner = -1;
	DWORD t0 = GetTickCount();
	int plen;
	const unsigned char *pkt = challenge(&plen);
	for (int i = 0; i < n; i++) {
		s[i] = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
		st[i] = ST_FAIL;
		if (s[i] == INVALID_SOCKET)
			continue;
		u_long nb = 1;
		ioctlsocket(s[i], FIONBIO, &nb);
		int r = g_realConnect(s[i], (struct sockaddr *)&c[i].a, sizeof c[i].a);
		if (r == 0) {
			if (tcp_first < 0)
				tcp_first = i;
			st[i] = send(s[i], (const char *)pkt, plen, 0) == plen ? ST_WAIT : ST_FAIL;
		} else
			st[i] = WSAGetLastError() == WSAEWOULDBLOCK ? ST_CONNECT : ST_FAIL;
	}
	while (winner < 0 && GetTickCount() - t0 < budget_ms) {
		fd_set wr, rd, ex;
		FD_ZERO(&wr); FD_ZERO(&rd); FD_ZERO(&ex);
		int any = 0;
		for (int i = 0; i < n; i++) {
			if (st[i] == ST_CONNECT) { FD_SET(s[i], &wr); FD_SET(s[i], &ex); any = 1; }
			if (st[i] == ST_WAIT) { FD_SET(s[i], &rd); any = 1; }
		}
		if (!any)
			break;
		DWORD left = budget_ms - (GetTickCount() - t0);
		struct timeval tv = {(long)(left / 1000), (long)(left % 1000) * 1000};
		if (select(0, &rd, &wr, &ex, &tv) <= 0)
			break;
		for (int i = 0; i < n && winner < 0; i++) {
			if (st[i] == ST_CONNECT && FD_ISSET(s[i], &ex))
				st[i] = ST_FAIL;
			else if (st[i] == ST_CONNECT && FD_ISSET(s[i], &wr)) {
				if (tcp_first < 0)
					tcp_first = i;
				st[i] = send(s[i], (const char *)pkt, plen, 0) == plen ? ST_WAIT : ST_FAIL;
			} else if (st[i] == ST_WAIT && FD_ISSET(s[i], &rd)) {
				unsigned char b[3];
				int got = recv(s[i], (char *)b, sizeof b, 0);
				if (got >= 2 && b[0] == 0x00) { /* AUTH_LOGON_CHALLENGE reply */
					st[i] = ST_DONE;
					winner = i;
				} else
					st[i] = ST_FAIL;
			}
		}
	}
	*ms_out = GetTickCount() - t0;
	{
		static const char *nm[] = {"no TCP", "no answer", "answered", "failed"};
		char line[400] = "", b[48];
		for (int i = 0; i < n; i++) {
			size_t L = strlen(line);
			snprintf(line + L, sizeof line - L, "%s%s %s", i ? ", " : "", addr_str(&c[i].a, b, sizeof b), nm[st[i]]);
		}
		ollog("  tried: %s", line);
	}
	for (int i = 0; i < n; i++)
		if (s[i] != INVALID_SOCKET)
			closesocket(s[i]);
	return winner >= 0 ? winner : -(tcp_first + 2); /* -1: nothing, <= -2: TCP only */
}

static const char *addr_str(const struct sockaddr_in *a, char *buf, size_t n)
{
	const unsigned char *b = (const unsigned char *)&a->sin_addr.s_addr;
	snprintf(buf, n, "%u.%u.%u.%u:%u", b[0], b[1], b[2], b[3], ntohs(a->sin_port));
	return buf;
}


/* ================================================================ world server
 * octoproxy's realm list fix, inside the game. When the login connection is made, the known
 * world addresses start being probed in the background (each probe waits for the server's
 * SMSG_AUTH_CHALLENGE; at most 3 new connections per second for all probes together, spread
 * evenly over the window). When the server sends the realm list, every realm's address is
 * replaced with the best candidate by loss, then median ping; the server's own pick is kept
 * if it lost nothing and is at most 20 ms slower than the best. A list that does not parse
 * exactly is passed through unchanged. While probing, the packet is held back without
 * freezing the game (select/recv report "no data yet"). */
#define MAX_WORLD 24
#define MAX_PROBES 12
typedef struct {
	struct sockaddr_in a;
	int ok, total;
	DWORD ms[MAX_PROBES];
	int offered;
} World;
static World g_world[MAX_WORLD];
static int g_nworld;
static CRITICAL_SECTION g_wlock;
static volatile LONG g_probing;          /* 1: probe window running */
static DWORD g_probeEnd;                 /* end of the window (GetTickCount) */
static DWORD g_lastProbeDone;            /* last finished window (results reused for 3 min) */
static SOCKET g_loginSock = INVALID_SOCKET;
static int g_expectRealm;                /* the client asked for the realm list */
static int g_framerDead;
static unsigned char g_cbuf[256]; static int g_clen;   /* client stream (framer) */
static unsigned char *g_hold; static int g_hlen, g_hcap; /* received from the server, held back */
static unsigned char *g_out; static int g_olen, g_opos;  /* to be handed to the game (rewritten) */

typedef int (WINAPI *send_t)(SOCKET, const char *, int, int);
typedef int (WINAPI *recv_t)(SOCKET, char *, int, int);
typedef int (WINAPI *select_t)(int, fd_set *, fd_set *, fd_set *, const struct timeval *);
typedef int (WINAPI *ioctl_t)(SOCKET, long, u_long *);
typedef int (WINAPI *close_t)(SOCKET);
static send_t g_realSend; static recv_t g_realRecv; static select_t g_realSelect;
static ioctl_t g_realIoctl; static close_t g_realClose;

static int world_index(const struct sockaddr_in *a)
{
	for (int i = 0; i < g_nworld; i++)
		if (same(&g_world[i].a, a))
			return i;
	return -1;
}

static int world_add(struct sockaddr_in a, int offered)
{
	int i = world_index(&a);
	if (i < 0 && g_nworld < MAX_WORLD) {
		i = g_nworld++;
		memset(&g_world[i], 0, sizeof g_world[i]);
		g_world[i].a = a;
	}
	if (i >= 0 && offered)
		g_world[i].offered = 1;
	return i;
}

/* one probe: connect + the 4-byte SMSG_AUTH_CHALLENGE header (opcode 0x01EC) */
static const char *addr_str(const struct sockaddr_in *a, char *buf, size_t n);
static DWORD probe_world(const struct sockaddr_in *a, DWORD timeout)
{
	SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
	if (s == INVALID_SOCKET)
		return 0;
	u_long nb = 1;
	ioctlsocket(s, FIONBIO, &nb);
	DWORD t0 = GetTickCount(), res = 0;
	int r = g_realConnect(s, (const struct sockaddr *)a, sizeof *a);
	if (r == 0 || WSAGetLastError() == WSAEWOULDBLOCK) {
		unsigned char h[4]; int got = 0, connected = r == 0;
		while (GetTickCount() - t0 < timeout) {
			fd_set w, rd, e; FD_ZERO(&w); FD_ZERO(&rd); FD_ZERO(&e);
			if (!connected) { FD_SET(s, &w); FD_SET(s, &e); } else FD_SET(s, &rd);
			DWORD left = timeout - (GetTickCount() - t0);
			struct timeval tv = {(long)(left / 1000), (long)(left % 1000) * 1000};
			if (select(0, &rd, &w, &e, &tv) <= 0 || FD_ISSET(s, &e))
				break;
			if (!connected) { connected = 1; continue; }
			int k = recv(s, (char *)h + got, 4 - got, 0);
			if (k <= 0)
				break;
			got += k;
			if (got == 4) {
				if ((h[2] | h[3] << 8) == 0x01EC)
					res = GetTickCount() - t0 ? GetTickCount() - t0 : 1;
				break;
			}
		}
	}
	closesocket(s);
	return res ? res : 0;
}

static DWORD median(DWORD *v, int n)
{
	for (int i = 1; i < n; i++)
		for (int j = i; j > 0 && v[j] < v[j - 1]; j--) { DWORD t = v[j]; v[j] = v[j - 1]; v[j - 1] = t; }
	return n ? v[n / 2] : 0;
}

static int g_rateMs = 334, g_windowMs = 8000, g_timeoutMs = 1500;
static int g_anyPort; /* tests only: treat candidates on any port as the same realm */

static DWORD WINAPI probe_thread(LPVOID unused)
{
	(void)unused;
	DWORD t0 = GetTickCount();
	DWORD next = t0;
	for (int round = 0;; round++) {
		EnterCriticalSection(&g_wlock);
		int n = g_nworld;
		LeaveCriticalSection(&g_wlock);
		int did = 0;
		for (int i = 0; i < n; i++) {
			EnterCriticalSection(&g_wlock);
			int need = g_world[i].total <= round && g_world[i].total < MAX_PROBES;
			struct sockaddr_in a = g_world[i].a;
			LeaveCriticalSection(&g_wlock);
			if (!need)
				continue;
			if (GetTickCount() - t0 >= (DWORD)g_windowMs)
				goto done;
			DWORD now = GetTickCount();
			if ((LONG)(next - now) > 0)
				Sleep(next - now);
			next = GetTickCount() + (DWORD)g_rateMs;
			DWORD ms = probe_world(&a, (DWORD)g_timeoutMs);
			EnterCriticalSection(&g_wlock);
			if (ms)
				g_world[i].ms[g_world[i].ok++] = ms;
			g_world[i].total++;
			LeaveCriticalSection(&g_wlock);
			did = 1;
		}
		if (!did && GetTickCount() - t0 >= (DWORD)g_windowMs)
			break;
		if (!did)
			Sleep(50);
	}
done:
	EnterCriticalSection(&g_wlock);
	for (int i = 0; i < g_nworld; i++) {
		char b[48]; DWORD tmp[MAX_PROBES]; memcpy(tmp, g_world[i].ms, sizeof tmp);
		ollog("  world %s: %d/%d answered, median %lu ms", addr_str(&g_world[i].a, b, sizeof b), g_world[i].ok, g_world[i].total, median(tmp, g_world[i].ok));
	}
	LeaveCriticalSection(&g_wlock);
	g_lastProbeDone = GetTickCount();
	InterlockedExchange(&g_probing, 0);
	return 0;
}

static void ini_world_list(char *out, DWORD n) { ini_get("worlds", "", out, n); }

/* Called on the login connection: collects the known world addresses and starts probing. */
static void start_world_probe(void)
{
	char tmp[16];
	ini_get("world", "1", tmp, sizeof tmp);
	if (tmp[0] == '0')
		return;
	char hosts[512], seen[1024];
	static char lastHosts[512];
	ini_get("world_hosts", "normal.octowow.st:8091,hc.octowow.st:8090,pvp.octowow.st:8092", hosts, sizeof hosts);
	if (g_lastProbeDone && GetTickCount() - g_lastProbeDone < 180000 && !strcmp(hosts, lastHosts))
		return; /* 3-minute cache (for the same server list) */
	memcpy(lastHosts, hosts, sizeof hosts);
	if (InterlockedCompareExchange(&g_probing, 1, 0))
		return;
	ini_get("world_window_ms", "8000", tmp, sizeof tmp); g_windowMs = atoi(tmp) < 1000 ? 8000 : atoi(tmp);
	ini_get("world_rate_ms", "334", tmp, sizeof tmp); g_rateMs = atoi(tmp) < 100 ? 334 : atoi(tmp);
	ini_get("world_timeout_ms", "1500", tmp, sizeof tmp); g_timeoutMs = atoi(tmp) < 200 ? 1500 : atoi(tmp);
	ini_world_list(seen, sizeof seen);
	Cand c[MAX_CAND * 3];
	int n = 0;
	/* add_list keeps at most MAX_CAND; two separate lists */
	n = add_list(c, 0, hosts, "dns");
	EnterCriticalSection(&g_wlock);
	g_nworld = 0;
	for (int i = 0; i < n; i++)
		world_add(c[i].a, 0);
	int m = add_list(c, 0, seen, "seen");
	for (int i = 0; i < m; i++)
		world_add(c[i].a, 0);
	int total = g_nworld;
	LeaveCriticalSection(&g_wlock);
	ini_get("test_any_port", "0", tmp, sizeof tmp); g_anyPort = tmp[0] == '1';
	g_probeEnd = GetTickCount() + (DWORD)g_windowMs;
	ollog("world: testing %d known world servers for %d ms", total, g_windowMs);
	HANDLE th = CreateThread(NULL, 0, probe_thread, NULL, 0, NULL);
	if (th)
		CloseHandle(th);
	else
		InterlockedExchange(&g_probing, 0);
}

/* --------------------------------------------------------------- realm list */
typedef struct { const unsigned char *p; int n, i, bad; } Rd;
static unsigned rd8(Rd *r) { if (r->i + 1 > r->n) { r->bad = 1; return 0; } return r->p[r->i++]; }
static unsigned rd32(Rd *r) { if (r->i + 4 > r->n) { r->bad = 1; return 0; } unsigned v = r->p[r->i] | r->p[r->i+1] << 8 | r->p[r->i+2] << 16 | (unsigned)r->p[r->i+3] << 24; r->i += 4; return v; }
static const char *rdstr(Rd *r) { const char *s = (const char *)r->p + r->i; while (r->i < r->n && r->p[r->i]) r->i++; if (r->i >= r->n) { r->bad = 1; return ""; } r->i++; return s; }

static int parse_addr(const char *s, struct sockaddr_in *a)
{
	char host[64]; const char *c = strrchr(s, ':');
	if (!c || c - s >= (int)sizeof host || c == s)
		return 0;
	memcpy(host, s, (size_t)(c - s)); host[c - s] = 0;
	int port = atoi(c + 1);
	unsigned long ip = inet_addr(host);
	if (port <= 0 || port > 65535 || ip == INADDR_NONE)
		return 0;
	memset(a, 0, sizeof *a); a->sin_family = AF_INET; a->sin_port = htons((u_short)port); a->sin_addr.s_addr = ip;
	return 1;
}

/* Remember the addresses the server offers in the realm list for later logins. */
static void remember_offered(const struct sockaddr_in *a, int n)
{
	char cur[1024], add[64], ini[MAX_PATH + 32];
	ini_world_list(cur, sizeof cur);
	for (int i = 0; i < n; i++) {
		addr_str(&a[i], add, sizeof add);
		if (strstr(cur, add))
			continue;
		size_t L = strlen(cur);
		if (L + strlen(add) + 2 >= sizeof cur)
			break;
		snprintf(cur + L, sizeof cur - L, "%s%s", L ? "," : "", add);
	}
	ini_path(ini, sizeof ini);
	WritePrivateProfileStringA("OctoLogin", "worlds", cur, ini);
}

/* Pick the best candidate (octoproxy's chooseWorld): reachable first, then loss, then median ping. */

static int choose(const struct sockaddr_in *offered, char *why, size_t wn)
{
	int port = ntohs(offered->sin_port), best = -1, oi = world_index(offered);
	DWORD bm = 0;
	for (int i = 0; i < g_nworld; i++) {
		World *w = &g_world[i];
		if ((!g_anyPort && ntohs(w->a.sin_port) != port) || !w->ok)
			continue;
		DWORD tmp[MAX_PROBES]; memcpy(tmp, w->ms, sizeof tmp);
		DWORD m = median(tmp, w->ok);
		if (best < 0) { best = i; bm = m; continue; }
		World *b = &g_world[best];
		/* loss comparison: a.fail/a.total < b.fail/b.total */
		long lhs = (long)(w->total - w->ok) * b->total, rhs = (long)(b->total - b->ok) * w->total;
		if (lhs < rhs || (lhs == rhs && m < bm)) { best = i; bm = m; }
	}
	if (best < 0) { snprintf(why, wn, "no candidate answered"); return oi; }
	if (oi >= 0 && oi != best && g_world[oi].ok) {
		World *o = &g_world[oi], *b = &g_world[best];
		DWORD tmp[MAX_PROBES]; memcpy(tmp, o->ms, sizeof tmp);
		DWORD om = median(tmp, o->ok);
		long lhs = (long)(b->total - b->ok) * o->total, rhs = (long)(o->total - o->ok) * b->total;
		if (!(lhs < rhs) && om <= bm + 20) { snprintf(why, wn, "offered: %lu ms, best %lu ms", om, bm); return oi; }
	}
	World *b = &g_world[best];
	snprintf(why, wn, "%lu ms, %d/%d answered", bm, b->ok, b->total);
	return best;
}

/* Rewrites a full realm list packet (header included); NULL if it does not parse. */
static unsigned char *rewrite(const unsigned char *pkt, int len, int *outlen)
{
	if (len < 3 || pkt[0] != 0x10 || (pkt[1] | pkt[2] << 8) != len - 3)
		return NULL;
	Rd r = {pkt + 3, len - 3, 0, 0};
	unsigned unk = rd32(&r); unsigned cnt = rd8(&r);
	if (r.bad || cnt > 64)
		return NULL;
	struct { unsigned icon; unsigned flags; const char *name, *addr; unsigned char tail[7]; } re[64];
	struct sockaddr_in off[64];
	for (unsigned i = 0; i < cnt; i++) {
		re[i].icon = rd32(&r); re[i].flags = rd8(&r); re[i].name = rdstr(&r); re[i].addr = rdstr(&r);
		for (int k = 0; k < 7; k++) re[i].tail[k] = (unsigned char)rd8(&r);
		if (r.bad || !parse_addr(re[i].addr, &off[i])) return NULL;
	}
	int trail = r.n - r.i;
	if (trail < 0 || trail > 4)
		return NULL;
	remember_offered(off, (int)cnt);
	unsigned char *o = malloc((size_t)len + 64 * 24);
	if (!o) return NULL;
	int n = 3;
	#define PUT32(v) do { o[n++] = (unsigned char)(v); o[n++] = (unsigned char)((v) >> 8); o[n++] = (unsigned char)((v) >> 16); o[n++] = (unsigned char)((v) >> 24); } while (0)
	PUT32(unk); o[n++] = (unsigned char)cnt;
	EnterCriticalSection(&g_wlock);
	for (unsigned i = 0; i < cnt; i++) {
		char why[96], buf[48], chosen[48];
		world_add(off[i], 1);
		int pick = choose(&off[i], why, sizeof why);
		snprintf(chosen, sizeof chosen, "%s", pick >= 0 ? addr_str(&g_world[pick].a, buf, sizeof buf) : re[i].addr);
		ollog("world %s: %s %s (%s)", re[i].name, same(&off[i], pick >= 0 ? &g_world[pick].a : &off[i]) ? "keeping" : "using", chosen, why);
		PUT32(re[i].icon); o[n++] = (unsigned char)re[i].flags;
		size_t L = strlen(re[i].name) + 1; memcpy(o + n, re[i].name, L); n += (int)L;
		L = strlen(chosen) + 1; memcpy(o + n, chosen, L); n += (int)L;
		memcpy(o + n, re[i].tail, 7); n += 7;
	}
	LeaveCriticalSection(&g_wlock);
	memcpy(o + n, r.p + r.i, (size_t)trail); n += trail;
	o[0] = 0x10; o[1] = (unsigned char)((n - 3) & 0xFF); o[2] = (unsigned char)((n - 3) >> 8);
	*outlen = n;
	return o;
}

/* client stream: find the realm list request (octoproxy's clientFramer) */
static void feed_client(const unsigned char *p, int n)
{
	if (g_framerDead) return;
	if (g_clen + n > (int)sizeof g_cbuf) { g_framerDead = 1; return; }
	memcpy(g_cbuf + g_clen, p, (size_t)n); g_clen += n;
	while (g_clen > 0) {
		int need;
		switch (g_cbuf[0]) {
		case 0x00: case 0x02: need = g_clen < 4 ? 0 : 4 + (g_cbuf[2] | g_cbuf[3] << 8); break;
		case 0x01: need = 1 + 32 + 20 + 20 + 1 + 1; break;
		case 0x03: need = 1 + 16 + 20 + 20 + 1; break;
		case 0x10: need = 5; break;
		default: g_framerDead = 1; g_clen = 0; return;
		}
		if (!need || g_clen < need) return;
		if (g_cbuf[0] == 0x10) g_expectRealm = 1;
		memmove(g_cbuf, g_cbuf + need, (size_t)(g_clen - need)); g_clen -= need;
	}
}

static int WINAPI hook_send(SOCKET s, const char *b, int n, int f)
{
	int r = g_realSend(s, b, n, f);
	if (s == g_loginSock && r > 0)
		feed_client((const unsigned char *)b, r);
	return r;
}

static void hold_append(const char *b, int n)
{
	if (g_hlen + n > g_hcap) { int c = (g_hlen + n) * 2; unsigned char *x = realloc(g_hold, (size_t)c); if (!x) return; g_hold = x; g_hcap = c; }
	memcpy(g_hold + g_hlen, b, (size_t)n); g_hlen += n;
}

/* once the held packet is complete and probing has finished, prepare the output */
static void try_release(void)
{
	if (g_olen || g_hlen < 3) return;
	int want = 3 + (g_hold[1] | g_hold[2] << 8);
	if (g_hlen < want) return;
	if (g_probing && (LONG)(g_probeEnd - GetTickCount()) > 0) return; /* still probing: keep holding */
	int on = 0;
	unsigned char *o = rewrite(g_hold, want, &on);
	if (!o) { ollog("world: realm list not recognised, passed through unchanged"); o = malloc((size_t)want); memcpy(o, g_hold, (size_t)want); on = want; }
	/* bytes that arrived after the packet go behind it */
	int extra = g_hlen - want;
	unsigned char *full = malloc((size_t)(on + extra));
	memcpy(full, o, (size_t)on); memcpy(full + on, g_hold + want, (size_t)extra); free(o);
	g_out = full; g_olen = on + extra; g_opos = 0; g_hlen = 0; g_expectRealm = 0;
}

static int pending(SOCKET s) { return s == g_loginSock && (g_hlen > 0 || g_olen > 0); }

static int WINAPI hook_recv(SOCKET s, char *b, int n, int f)
{
	if (s != g_loginSock || (!g_expectRealm && !g_olen && !g_hlen))
		return g_realRecv(s, b, n, f);
	if (g_olen) {
		int k = g_olen - g_opos < n ? g_olen - g_opos : n;
		memcpy(b, g_out + g_opos, (size_t)k); g_opos += k;
		if (g_opos >= g_olen) { free(g_out); g_out = NULL; g_olen = g_opos = 0; }
		return k;
	}
	/* hold back everything from the server */
	char tmp[4096];
	int r = g_realRecv(s, tmp, sizeof tmp, f);
	if (r > 0) {
		if (!g_hlen && (unsigned char)tmp[0] != 0x10) { g_expectRealm = 0; int k = r < n ? r : n; memcpy(b, tmp, (size_t)k); if (k < r) { g_out = malloc((size_t)(r - k)); memcpy(g_out, tmp + k, (size_t)(r - k)); g_olen = r - k; } return k; }
		hold_append(tmp, r);
	} else if (r == 0 || (r < 0 && WSAGetLastError() != WSAEWOULDBLOCK)) {
		if (!g_hlen) return r;
	}
	try_release();
	if (g_olen) return hook_recv(s, b, n, f);
	WSASetLastError(WSAEWOULDBLOCK);
	return SOCKET_ERROR;
}

static int WINAPI hook_select(int nfds, fd_set *rd, fd_set *wr, fd_set *ex, const struct timeval *tv)
{
	if (g_loginSock == INVALID_SOCKET || !rd || !FD_ISSET(g_loginSock, rd) || !pending(g_loginSock))
		return g_realSelect(nfds, rd, wr, ex, tv);
	try_release();
	if (g_olen) { /* data ready: report only this socket as readable */
		FD_ZERO(rd); FD_SET(g_loginSock, rd);
		if (wr) FD_ZERO(wr);
		if (ex) FD_ZERO(ex);
		return 1;
	}
	/* held: a real select to receive the rest, with a short timeout */
	struct timeval t = {0, 50000};
	int r = g_realSelect(nfds, rd, wr, ex, &t);
	return r;
}

static int WINAPI hook_ioctl(SOCKET s, long cmd, u_long *arg)
{
	if (cmd == (long)FIONREAD && pending(s) && arg) {
		try_release();
		*arg = (u_long)(g_olen ? g_olen - g_opos : 0);
		return 0;
	}
	return g_realIoctl(s, cmd, arg);
}

static int WINAPI hook_close(SOCKET s)
{
	if (s == g_loginSock) {
		g_loginSock = INVALID_SOCKET; g_expectRealm = 0; g_framerDead = 0; g_clen = 0; g_hlen = 0;
		free(g_out); g_out = NULL; g_olen = g_opos = 0;
	}
	return g_realClose(s);
}

/* ---------------------------------------------------------------- connect hook */
static int WINAPI hook_connect(SOCKET sock, const struct sockaddr *name, int namelen)
{
	if (!name || namelen < (int)sizeof(struct sockaddr_in) || name->sa_family != AF_INET)
		return g_realConnect(sock, name, namelen);
	const struct sockaddr_in *dst = (const struct sockaddr_in *)name;
	if (ntohs(dst->sin_port) != LOGIN_PORT)
		return g_realConnect(sock, name, namelen);
	const unsigned char *ip = (const unsigned char *)&dst->sin_addr.s_addr;
	char buf[64], hosts[512], extra[512], last[64], tmp[8];
	ini_get("enabled", "1", tmp, sizeof tmp);
	if (tmp[0] == '0')
		return g_realConnect(sock, name, namelen);
	ini_get("skiploopback", "1", tmp, sizeof tmp);
	if (ip[0] == 127 && tmp[0] != '0') {
		ollog("login %s: local proxy, left alone", addr_str(dst, buf, sizeof buf));
		return g_realConnect(sock, name, namelen);
	}
	Cand c[MAX_CAND];
	int n = 0;
	ini_get("hosts", "play.octowow.st,normal.octowow.st", hosts, sizeof hosts);
	ini_get("extra", "185.246.188.177", extra, sizeof extra);
	ini_get("lastgood", "", last, sizeof last);
	n = add_list(c, n, hosts, "dns");
	n = add_list(c, n, extra, "fallback");
	int known = 0;
	for (int i = 0; i < n; i++)
		if (same(&c[i].a, dst))
			known = 1;
	if (!known) {
		ollog("login %s: not an OctoWoW address, left alone", addr_str(dst, buf, sizeof buf));
		return g_realConnect(sock, name, namelen);
	}
	/* order: the game's own target, the last good one, the rest (ties go to the earlier one) */
	Cand o[MAX_CAND];
	int m = 0;
	m = add_cand(o, m, *dst, "realmlist");
	if (last[0])
		m = add_list(o, m, last, "last good");
	for (int i = 0; i < n; i++)
		m = add_cand(o, m, c[i].a, c[i].why);
	ini_get("budget_ms", "3500", tmp, sizeof tmp);
	DWORD budget = (DWORD)atoi(tmp);
	if (budget < 500 || budget > 10000)
		budget = 3500;
	DWORD ms;
	int w = race(o, m, budget, &ms);
	struct sockaddr_in use = *dst;
	if (w >= 0) {
		use = o[w].a;
		ollog("login: %s answered first in %lu ms (%s, %d tried)", addr_str(&use, buf, sizeof buf), ms, o[w].why, m);
		char ini[MAX_PATH + 32];
		ini_path(ini, sizeof ini);
		WritePrivateProfileStringA("OctoLogin", "lastgood", addr_str(&use, buf, sizeof buf), ini);
	} else if (w <= -2) {
		use = o[-w - 2].a;
		ollog("login: no login service answered in %lu ms; using %s (TCP open, %s)", ms, addr_str(&use, buf, sizeof buf), o[-w - 2].why);
	} else {
		ollog("login: nothing answered in %lu ms (%d tried); using the realmlist address", ms, m);
	}
	g_loginSock = sock; g_expectRealm = 0; g_framerDead = 0; g_clen = 0; g_hlen = 0;
	start_world_probe();
	return g_realConnect(sock, (const struct sockaddr *)&use, sizeof use);
}

/* ---------------------------------------------------------------- install */
static int hook_slot(HMODULE ws, int ord, uintptr_t addr, void *hook, void **orig)
{
	FARPROC want = GetProcAddress(ws, MAKEINTRESOURCEA(ord));
	void **slot = (void **)addr;
	if (!want || *slot != (void *)want)
		return 0;
	*orig = (void *)want;
	DWORD old;
	if (!VirtualProtect(slot, sizeof *slot, PAGE_READWRITE, &old))
		return 0;
	*slot = hook;
	VirtualProtect(slot, sizeof *slot, old, &old);
	return 1;
}

static int install(void)
{
	HMODULE ws = GetModuleHandleA("wsock32.dll");
	if (!ws)
		ws = LoadLibraryA("wsock32.dll");
	FARPROC want = ws ? GetProcAddress(ws, MAKEINTRESOURCEA(4)) : NULL;
	void **slot = (void **)(uintptr_t)ADDR_IAT_CONNECT;
	MEMORY_BASIC_INFORMATION mbi;
	if (!want || !VirtualQuery(slot, &mbi, sizeof mbi) || mbi.State != MEM_COMMIT) {
		ollog("OctoLogin %s: not WoW 1.12.1 (no import table at 0x%08X); doing nothing", OL_VERSION, ADDR_IAT_CONNECT);
		return 0;
	}
	if (*slot != (void *)want) {
		ollog("OctoLogin %s: connect import already changed by another mod; doing nothing", OL_VERSION);
		return 0;
	}
	g_realConnect = (connect_t)want;
	DWORD old;
	if (!VirtualProtect(slot, sizeof *slot, PAGE_READWRITE, &old))
		return 0;
	*slot = (void *)hook_connect;
	VirtualProtect(slot, sizeof *slot, old, &old);
	/* world server: send/recv/select/ioctlsocket/closesocket (all of them or none) */
	void *o1, *o2, *o3, *o4, *o5;
	void **sl[] = {(void **)0x007FF70Cu, (void **)0x007FF714u, (void **)0x007FF708u, (void **)0x007FF718u, (void **)0x007FF704u};
	int ords[] = {19, 16, 18, 10, 3};
	int okall = 1;
	for (int i = 0; i < 5; i++) {
		FARPROC w = GetProcAddress(ws, MAKEINTRESOURCEA(ords[i]));
		if (!w || *sl[i] != (void *)w) okall = 0;
	}
	if (okall && hook_slot(ws, 19, 0x007FF70Cu, (void *)hook_send, &o1) && hook_slot(ws, 16, 0x007FF714u, (void *)hook_recv, &o2)
	    && hook_slot(ws, 18, 0x007FF708u, (void *)hook_select, &o3) && hook_slot(ws, 10, 0x007FF718u, (void *)hook_ioctl, &o4)
	    && hook_slot(ws, 3, 0x007FF704u, (void *)hook_close, &o5)) {
		g_realSend = (send_t)o1; g_realRecv = (recv_t)o2; g_realSelect = (select_t)o3; g_realIoctl = (ioctl_t)o4; g_realClose = (close_t)o5;
		ollog("OctoLogin %s: ready (login + world)", OL_VERSION);
	} else
		ollog("OctoLogin %s: ready (login only; world hooks unavailable)", OL_VERSION);
	return 1;
}

BOOL WINAPI DllMain(HINSTANCE h, DWORD reason, LPVOID r)
{
	(void)r;
	if (reason == DLL_PROCESS_ATTACH) {
		DisableThreadLibraryCalls(h);
		InitializeCriticalSection(&g_logLock);
		InitializeCriticalSection(&g_wlock);
		GetModuleFileNameA(h, g_dir, sizeof g_dir);
		char *sl = strrchr(g_dir, '\\');
		if (sl)
			sl[1] = 0;
		install();
	}
	return TRUE;
}
