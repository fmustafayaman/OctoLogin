#!/bin/zsh
# Builds OctoLogin.dll and the test harness, starts local fake login/world servers
# and runs the harness under Wine.
set -e
cd "${0:A:h}/.."
WINE=${WINE:-/Applications/WoWSilicon.app/Contents/Resources/Wine/bin/wine}
export WINEDEBUG=-all DYLD_LIBRARY_PATH=${DYLD_LIBRARY_PATH:-/Applications/WoWSilicon.app/Contents/Resources/Wine/lib/external} WINEPREFIX=${WINEPREFIX:-$HOME/.cache/hdtoggle-wine}
i686-w64-mingw32-gcc -O2 -Wall -Wextra -Werror -std=c11 -shared -s -static-libgcc -mcrtdll=msvcrt-os -o dll/OctoLogin.dll dll/octologin.c -lws2_32
i686-w64-mingw32-gcc -O1 -s -Wall -std=c11 -static-libgcc -mcrtdll=msvcrt-os -Wl,--image-base,0x400000 -Wl,--section-start=.wowiat=0x007FF000 -o test/harness.exe test/harness.c -lws2_32
python3 - <<'PY' &
import socket, threading, time, os
def srv(port_file, mode):
    s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(("127.0.0.1",0)); s.listen(16)
    open(port_file,"w").write(str(s.getsockname()[1]))
    while True:
        c,_=s.accept()
        def h(c=c):
            try:
                if mode=="good": c.recv(64); time.sleep(0.2); c.sendall(b"\x00\x00\x04")
                else: time.sleep(10)
            finally: c.close()
        threading.Thread(target=h,daemon=True).start()
def world(port_file, mode):
    s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(("127.0.0.1",0)); s.listen(64)
    open(port_file,"w").write(str(s.getsockname()[1]))
    while True:
        c,_=s.accept()
        def h(c=c):
            try:
                if mode=="fast": c.sendall(b"\x00\x06\xec\x01")
                elif mode=="slow": time.sleep(0.06); c.sendall(b"\x00\x06\xec\x01")
                elif mode=="near": time.sleep(0.008); c.sendall(b"\x00\x06\xec\x01")
                else: time.sleep(5)
                time.sleep(0.2)
            finally: c.close()
        threading.Thread(target=h,daemon=True).start()
def login(port_file):
    s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(("127.0.0.1",0)); s.listen(16)
    open(port_file,"w").write(str(s.getsockname()[1]))
    while True:
        c,_=s.accept()
        def h(c=c):
            try:
                b=c.recv(1)
                if b==b"\x00": c.recv(256); c.sendall(b"\x00\x00\x04"); return
                if b==b"\x10":
                    c.recv(4)
                    while not all(os.path.exists(f"/tmp/ol_w{m}") for m in ("fast","slow","dead","near")): time.sleep(0.05)
                    P={m:open(f"/tmp/ol_w{m}").read() for m in ("fast","slow","dead","near")}
                    import struct
                    body=struct.pack("<IB",0,3)
                    for name,port in (("N'Zoth",P["dead"]),("C'Thun",P["slow"]),("Y'Shaarj",P["near"])):
                        body+=struct.pack("<IB",1,0)+name.encode()+b"\0"+f"127.0.0.1:{port}".encode()+b"\0"+struct.pack("<f",1.0)+bytes([1,1,0])
                    body+=b"\x10\x00"
                    c.sendall(b"\x10"+struct.pack("<H",len(body))+body); time.sleep(1)
            finally: c.close()
        threading.Thread(target=h,daemon=True).start()
for name,mode in (("silent","silent"),("good","good")):
    threading.Thread(target=srv,args=(f"/tmp/ol_{name}",mode),daemon=True).start()
for m in ("fast","slow","dead","near"):
    threading.Thread(target=world,args=(f"/tmp/ol_w{m}",m),daemon=True).start()
threading.Thread(target=login,args=("/tmp/ol_login",),daemon=True).start()
s=socket.socket(); s.bind(("127.0.0.1",0)); open("/tmp/ol_closed","w").write(str(s.getsockname()[1])); s.close()
time.sleep(120)
PY
SP=$!; trap "kill $SP 2>/dev/null; rm -f /tmp/ol_silent /tmp/ol_good /tmp/ol_closed /tmp/ol_login /tmp/ol_w*" EXIT
for i in {1..50}; do [[ -s /tmp/ol_silent && -s /tmp/ol_good && -s /tmp/ol_closed && -s /tmp/ol_login && -s /tmp/ol_wfast && -s /tmp/ol_wslow && -s /tmp/ol_wdead && -s /tmp/ol_wnear ]] && break; sleep 0.1; done
T=$(mktemp -d); cp dll/OctoLogin.dll test/harness.exe $T/
(cd $T && perl -e 'alarm 60; exec @ARGV' "$WINE" harness.exe OctoLogin.dll $(cat /tmp/ol_silent) $(cat /tmp/ol_good) $(cat /tmp/ol_closed) $(cat /tmp/ol_login) $(cat /tmp/ol_wfast) $(cat /tmp/ol_wslow) $(cat /tmp/ol_wdead) $(cat /tmp/ol_wnear) 2>&1 | grep -v -i -E 'freetype|truetype'; echo "-- OctoLogin.log --"; cat OctoLogin.log)
rm -rf $T
