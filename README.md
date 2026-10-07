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

**World server.** Once you are logged in and the game asks for the realm list, OctoLogin tests
the known world servers in the background. Nothing but the login itself talks to the servers
while the game authenticates.
A test waits for the world server's real greeting (`SMSG_AUTH_CHALLENGE`), not just a TCP
handshake. The known world servers are the ones `normal`, `hc` and `pvp.octowow.st` resolve to, a
built-in list of servers OctoWoW has used that are not in DNS, and every address OctoWoW offers
in a realm list (remembered for later logins). When the realm list arrives, each realm's
address is replaced with the best server:
fewest failed tests first, then the lowest median ping. OctoWoW's own pick is kept if it lost
nothing and is at most 20 ms slower than the best. The world addresses OctoWoW offers are
remembered, so servers that are not in DNS are tested on the next login.

The realm list is held back for the length of the test window (8 seconds by default), so you
will see "Retrieving realm list" a little longer. The game does not freeze meanwhile.

## Being gentle with the DDoS filter

OctoWoW's DDoS protection punishes bursts of new connections from one IP. OctoLogin only
connects while you log in, never during play:

- login: one attempt per address, at most 8 addresses;
- world: only after the login succeeded, at most 2 tests per server and at most 3 new
  connections per second for all servers together, spread over the window;
- a second login within 3 minutes reuses the results instead of testing again.

## Safety

- It only acts when the game connects to an OctoWoW login address on port 3724. Other servers,
  other ports and local addresses (`127.x`, for a proxy such as octoproxy) are left alone.
- A realm list that does not decode exactly is passed through unchanged. The worst case is a
  normal login.
- It changes a single entry of the game's import table, `connect`, and only if it is
  untouched; if another mod already hooked it, OctoLogin does nothing.

## Install

The setup script finds your game folder, installs the latest release, adds it to `dlls.txt`
and checks everything OctoLogin needs. Run it again any time: it only fixes what is wrong.

**Windows:** open PowerShell (Start menu, type `powershell`) and paste:

```powershell
irm https://raw.githubusercontent.com/fmustafayaman/OctoLogin/main/install/install.ps1 | iex
```

Or download [`OctoLogin-Setup.bat`](install/OctoLogin-Setup.bat) and double-click it.

**Linux and macOS** (Wine, Lutris, Steam/Proton, CrossOver):

```sh
curl -fsSL https://raw.githubusercontent.com/fmustafayaman/OctoLogin/main/install/install.sh | bash
```

Then start the game with `VanillaFixes.exe` (or the OctoWoW launcher). The first time,
VanillaFixes asks whether to load the DLLs in `dlls.txt`: press OK.

**Is it working?** After logging in once, run the check. It changes nothing and tells you what
is wrong: OctoLogin missing or old, a broken `dlls.txt`, VanillaFixes missing, the game started
without VanillaFixes, a realmlist that points to octoproxy, and what OctoLogin did at your last
login.

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/fmustafayaman/OctoLogin/main/install/install.ps1))) -Check
```

```sh
curl -fsSL https://raw.githubusercontent.com/fmustafayaman/OctoLogin/main/install/install.sh | bash -s -- --check
```

`-Uninstall` / `--uninstall` removes OctoLogin. If the game folder is not found, pass it:
`-Game "D:\Games\OctoWoW"` / `bash -s -- "/path/to/OctoWoW"`.

### By hand

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
./test/run_tests.sh     # 27 tests under Wine with local fake login and world servers
```

The test harness places fake Winsock import slots at the same addresses as `WoW.exe`, then
plays the game's side of the login: it picks between silent, closed and working login servers,
checks that the login runs through the relay, reads the realm list in small pieces and checks
which world server each realm gets.

`test/live_test.c` makes one login attempt against the real OctoWoW login servers (world testing
off). Use it sparingly.

## How it works

`WoW.exe` (1.12.1, build 5875) imports Winsock from `WSOCK32.dll` by ordinal. OctoLogin replaces
one import table entry, `connect` (`0x7FF6D0`). The rest of the game's networking is untouched.

When the game connects to an OctoWoW login address, OctoLogin runs the login race, connects to
the winner and starts a small relay on the loopback interface (`127.0.0.1`, a random port, inside
the game process). The game is connected to the relay, which copies the login traffic both ways,
the same way octoproxy does with `realmlist 127.0.0.1`. The relay watches the game's side only for
the realm list request, and holds back the server's realm list reply until the world tests are
done, then rewrites it. Everything else passes through byte for byte. The world server
connection is made by the game directly, without the relay.

The realm list parser and the ranking rules are ported from octoproxy.

## octoproxy

octoproxy is the standalone version: a local login proxy that does the same login and world
server selection outside the game. OctoLogin replaces it; if you still run octoproxy
(`realmlist 127.0.0.1`), OctoLogin leaves it alone.

## Changes

**1.1.0**
- Only the game's `connect` is hooked. The login connection runs through a loopback relay
  inside the game instead of hooking `send`, `recv`, `select`, `ioctlsocket` and
  `closesocket`. Hooking those in `WoW.exe` is what old WoW password stealers did, and a few
  antivirus engines flagged 1.0.2 for it (false positive). OctoLogin never read or sent any
  account data, and still does not.
- The DLL carries version information (product, version, license, source link).

**1.0.2**
- World tests no longer wait for each other: a slow server (or a slow VPN) cannot use up the
  window, and a test waits up to 3 seconds for the greeting. At most 2 tests per server.
- A built-in list of world servers OctoWoW has offered that are not in DNS. One of them kept
  N'Zoth reachable when the servers OctoWoW offered at the time did not answer.
- More than 8 remembered world addresses are used (earlier ones past the 8th were dropped).
- The realm list is handed over as soon as all tests have finished, not only at the end of the
  window.

**1.0.1** (pre-release): world servers are tested only after the login succeeded (when the game
asks for the realm list), not while the game authenticates.

**1.0.0**: first release.

## License

MIT. See [LICENSE](LICENSE).
