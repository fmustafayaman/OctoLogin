# OctoLogin

A small DLL mod for [OctoWoW](https://octowow.st) (WoW 1.12.1) that keeps your login working
while OctoWoW moves its servers around, and sends the game to the world server with the least
packet loss and the lowest ping. It is octoproxy built into the game: nothing else
to run, and your `realmlist.wtf` can stay as it is.

## What it does

**Login.** When the game connects to the login server, OctoLogin tries every known OctoWoW login
address at the same time and gives the game the first one whose login service actually answers.
The known addresses are:

- the address in your `realmlist.wtf`,
- every IP that `play.octowow.st` and `normal.octowow.st` resolve to, looked up on each login,
- fallback addresses that are not in DNS (`extra=` in the settings),
- the address that worked last time.

Each address is tried once per login: a TCP connection and a logon challenge for an account name
that does not exist, so the server answers without anything being logged in. If nothing answers,
the game's own address is used, exactly as without the mod.

**World server.** While you log in, OctoLogin tests the known world servers in the background.
A test waits for the world server's real greeting (`SMSG_AUTH_CHALLENGE`), not just a TCP
handshake. When the realm list arrives, each realm's address is replaced with the best server:
fewest failed tests first, then the lowest median ping. OctoWoW's own pick is kept if it lost
nothing and is at most 20 ms slower than the best. The world addresses OctoWoW offers are
remembered, so servers that are not in DNS are tested on the next login.

The realm list is held back for the length of the test window (8 seconds by default), so you
will see "Retrieving realm list" a little longer. The game does not freeze meanwhile.

## Being gentle with the DDoS filter

OctoWoW's DDoS protection punishes bursts of new connections from one IP. OctoLogin only
connects while you log in, never during play:

- login: one attempt per address, at most 8 addresses;
- world: at most 3 new connections per second for all servers together, spread over the window;
- a second login within 3 minutes reuses the results instead of testing again.

## Safety

- It only acts when the game connects to an OctoWoW login address on port 3724. Other servers,
  other ports and local addresses (`127.x`, for a proxy such as octoproxy) are left alone.
- A realm list that does not decode exactly is passed through unchanged. The worst case is a
  normal login.
- It patches the game's Winsock import table only if the entries are untouched; if another mod
  already hooked them, OctoLogin does nothing.

## Install

1. Download `OctoLogin.dll` from the [releases](../../releases) page.
2. Copy it into your game's `mods` folder.
3. Add this line to the end of `dlls.txt` in your game folder:
   ```
   mods/OctoLogin.dll
   ```
4. Start the game.

Requires a DLL loader that reads `dlls.txt` (VanillaFixes / the OctoWoW launcher).

## Settings and log

OctoLogin works without settings. To change something, copy
[`OctoLogin.ini.example`](OctoLogin.ini.example) to `mods/OctoLogin.ini` and edit it.
`enabled=0` turns the mod off.

Everything it does is written to `mods/OctoLogin.log`:

```
login: 92.114.107.48:3724 answered first in 112 ms (dns, 4 tried)
world: testing 5 known world servers for 8000 ms
world N'Zoth: using 92.114.107.53:8091 (113 ms, 5/5 answered)
world C'Thun: using 92.114.107.47:8090 (118 ms, 5/5 answered)
```

## Build and test

Needs MinGW-w64 (`i686-w64-mingw32-gcc`).

```sh
./build.sh              # dll/OctoLogin.dll
./test/run_tests.sh     # 21 tests under Wine with local fake login and world servers
```

The test harness places fake Winsock import slots at the same addresses as `WoW.exe`, then
plays the game's side of the login: it picks between silent, closed and working login servers,
reads the realm list in small pieces through the hooked `select`/`recv`, and checks which world
server each realm gets.

`test/live_test.c` makes one login attempt against the real OctoWoW login servers (world testing
off). Use it sparingly.

## How it works

`WoW.exe` (1.12.1, build 5875) imports Winsock from `WSOCK32.dll` by ordinal. OctoLogin replaces
these import table entries:

| Slot       | Function    | Used for |
|------------|-------------|----------|
| `0x7FF6D0` | connect     | login race, start of world testing |
| `0x7FF70C` | send        | spotting the client's realm list request |
| `0x7FF714` | recv        | holding back and rewriting the realm list |
| `0x7FF708` | select      | reporting "no data yet" while the list is held |
| `0x7FF718` | ioctlsocket | the same for `FIONREAD` |
| `0x7FF704` | closesocket | forgetting the login connection |

The realm list parser and the ranking rules are ported from octoproxy.

## octoproxy

octoproxy is the standalone version: a local login proxy that does the same login and world
server selection outside the game. OctoLogin replaces it; if you still run octoproxy
(`realmlist 127.0.0.1`), OctoLogin leaves it alone.

## License

MIT. See [LICENSE](LICENSE).
