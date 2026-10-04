#!/bin/sh
# Builds OctoLogin.dll (32-bit, for WoW 1.12.1) with MinGW-w64.
set -e
cd "$(dirname "$0")"
i686-w64-mingw32-gcc -O2 -Wall -Wextra -Werror -std=c11 -shared -s -static-libgcc -mcrtdll=msvcrt-os \
	-o dll/OctoLogin.dll dll/octologin.c -lws2_32
echo "built dll/OctoLogin.dll"
