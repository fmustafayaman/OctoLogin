/* One gentle login attempt against the real OctoWoW login servers (world probing off). */
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <windows.h>
#include <stdio.h>
#include <stdint.h>
typedef int (WINAPI *connect_t)(SOCKET, const struct sockaddr *, int);
__attribute__((section(".wowiat"), used)) void *wow_iat[0x400] = {(void *)1};
int main(int argc, char **argv)
{
	(void)argc;
	WSADATA w; WSAStartup(MAKEWORD(2, 2), &w);
	HMODULE ws = LoadLibraryA("wsock32.dll");
	int ords[] = {4, 19, 16, 18, 10, 3}; uintptr_t at[] = {0x7FF6D0, 0x7FF70C, 0x7FF714, 0x7FF708, 0x7FF718, 0x7FF704};
	for (int i = 0; i < 6; i++) *(void **)at[i] = (void *)GetProcAddress(ws, MAKEINTRESOURCEA(ords[i]));
	DeleteFileA(".\\OctoLogin.ini");
	WritePrivateProfileStringA("OctoLogin", "world", "0", ".\\OctoLogin.ini");
	LoadLibraryA(argv[1]);
	struct hostent *he = gethostbyname("play.octowow.st");
	if (!he) { printf("no DNS\n"); return 1; }
	struct sockaddr_in a = {0}; a.sin_family = AF_INET; a.sin_port = htons(3724); memcpy(&a.sin_addr, he->h_addr_list[0], 4);
	SOCKET s = socket(AF_INET, SOCK_STREAM, 0);
	DWORD t = GetTickCount();
	int r = ((connect_t)*(void **)0x7FF6D0)(s, (struct sockaddr *)&a, sizeof a);
	struct sockaddr_in p; int pl = sizeof p; getpeername(s, (struct sockaddr *)&p, &pl);
	printf("game target %s -> connected to %s:%d, result %d, %lu ms\n", inet_ntoa(a.sin_addr), inet_ntoa(p.sin_addr), ntohs(p.sin_port), r, GetTickCount() - t);
	closesocket(s);
	return 0;
}
