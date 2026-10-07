#!/usr/bin/env bash
# OctoLogin installer and checker for Linux and macOS (Wine, Lutris, Steam/Proton, CrossOver, ...).
#
#   curl -fsSL https://raw.githubusercontent.com/fmustafayaman/OctoLogin/main/install/install.sh | bash
#
# Options (after "bash -s --" when piped):
#   --check          only check, change nothing
#   --uninstall      remove OctoLogin
#   <folder>         the game folder (the one with WoW.exe); found automatically if left out
#
# Installs the latest release into <game>/mods, adds it to dlls.txt, fixes what it can and
# reports what it cannot. Running it again is safe: it only changes what is wrong.

set -u

REPO="fmustafayaman/OctoLogin"
LINE="mods/OctoLogin.dll"

MODE=install
GAME=""
for a in "$@"; do
	case "$a" in
		--check) MODE=check ;;
		--uninstall) MODE=uninstall ;;
		-h|--help) sed -n '2,12p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
		-*) echo "unknown option: $a" >&2; exit 2 ;;
		*) GAME="$a" ;;
	esac
done

# ------------------------------------------------------------------ output
# Turkish or English, from OCTOLOGIN_LANG, the locale, or (macOS without a locale) the system language.
LANG_TR=0
lc="${OCTOLOGIN_LANG:-${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}}"
if [ -z "$lc" ] && [ "$(uname)" = Darwin ]; then
	lc=$(defaults read -g AppleLanguages 2>/dev/null | sed -n 2p | tr -d ' "')
fi
case "$lc" in tr*) LANG_TR=1 ;; esac
t() { if [ "$LANG_TR" = 1 ]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }

if [ -t 1 ]; then G=$'\033[32m' Y=$'\033[33m' R=$'\033[31m' B=$'\033[1m' N=$'\033[0m'; else G='' Y='' R='' B='' N=''; fi
PROBLEMS=0
WARNINGS=0
ok()   { printf '  %s[ OK ]%s %s\n' "$G" "$N" "$1"; }
warn() { printf '  %s[ !! ]%s %s\n' "$Y" "$N" "$1"; WARNINGS=$((WARNINGS + 1)); }
bad()  { printf '  %s[ XX ]%s %s\n' "$R" "$N" "$1"; PROBLEMS=$((PROBLEMS + 1)); }
info() { printf '         %s\n' "$1"; }
step() { printf '\n%s%s%s\n' "$B" "$1" "$N"; }

# Reads an answer from the terminal (works when the script itself comes from a pipe).
ask() {
	local reply=""
	if [ -r /dev/tty ] && { exec 3</dev/tty; } 2>/dev/null; then
		printf '%s' "$1" >/dev/tty
		IFS= read -r reply <&3 || reply=""
		exec 3<&-
		printf '%s' "$reply"
		return 0
	fi
	return 1
}

# ------------------------------------------------------------------ helpers
# Prints the file in $1 whose name is $2, ignoring case (Wine does not care about case).
ci() { find "$1" -maxdepth 1 -iname "$2" 2>/dev/null | head -n 1; }

sha256() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
	else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

fetch() { # url [output file]
	if command -v curl >/dev/null 2>&1; then
		if [ $# -gt 1 ]; then curl -fsSL --retry 2 -o "$2" "$1"; else curl -fsSL --retry 2 "$1"; fi
	elif command -v wget >/dev/null 2>&1; then
		if [ $# -gt 1 ]; then wget -q -O "$2" "$1"; else wget -q -O - "$1"; fi
	else
		return 127
	fi
}

mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
datestr() { date -d "@$1" '+%Y-%m-%d %H:%M' 2>/dev/null || date -r "$1" '+%Y-%m-%d %H:%M'; }

rel() { printf '%s' "${1#"$GAME"/}"; } # path inside the game folder, for messages

is_game() { [ -n "$(ci "$1" wow.exe)" ] && [ -n "$(ci "$1" data)" ]; }

# "1.12.1.5875" from the version resource of WoW.exe in $1 (empty if it has none).
wow_version() {
	LC_ALL=C tr -d '\000' <"$(ci "$1" wow.exe)" 2>/dev/null | LC_ALL=C grep -a -o -m 1 'FileVersion[0-9][0-9, ]*' |
		head -n 1 | sed 's/FileVersion//; s/, */./g; s/[. ]*$//'
}
is_vanilla() { case "$(wow_version "$1")" in ''|1.12.*) return 0 ;; *) return 1 ;; esac; }

# Lines of dlls.txt that load an OctoLogin.dll (not commented out), as "number<TAB>text".
octo_lines() {
	awk '{ l = $0; sub(/\r$/, "", l); if (substr(l, 1, 1) == "#") next
	       gsub(/^ +| +$/, "", l); k = tolower(l); gsub(/\\/, "/", k)
	       if (k ~ /(^|\/)octologin\.dll$/) print NR "\t" l }' "$1"
}

# ------------------------------------------------------------------ find the game folder
# Folders of a running WoW.exe / VanillaFixes.exe under Wine (Linux only).
running_games() {
	[ -d /proc ] || return 0
	local p exe prefix letter rest base
	for p in /proc/[0-9]*; do
		exe=$(tr '\0' '\n' <"$p/cmdline" 2>/dev/null | head -n 1)
		case "$(printf '%s' "$exe" | tr 'A-Z' 'a-z')" in *wow.exe|*vanillafixes.exe) ;; *) continue ;; esac
		case "$exe" in
			[A-Za-z]:\\*)
				prefix=$(tr '\0' '\n' <"$p/environ" 2>/dev/null | sed -n 's/^WINEPREFIX=//p' | head -n 1)
				[ -n "$prefix" ] || prefix="$HOME/.wine"
				letter=$(printf '%s' "${exe%%:*}" | tr 'A-Z' 'a-z')
				base=$(cd "$prefix/dosdevices/$letter:" 2>/dev/null && pwd -P) || continue
				rest=$(printf '%s' "${exe#?:}" | tr '\\' '/')
				printf '%s\n' "$(dirname "$base$rest")"
				;;
			/*) printf '%s\n' "$(dirname "$exe")" ;;
		esac
	done
}

search_games() {
	local roots=() r
	for r in "$HOME" /mnt /media /run/media /opt /games /Applications /Volumes \
		"$HOME/Library/Application Support/CrossOver/Bottles"; do
		[ -d "$r" ] && roots+=("$r")
	done
	find "${roots[@]}" -maxdepth 9 \
		\( -name proc -o -name node_modules -o -name .git -o -name .cache -o -name Trash -o -name .Trash \
		   -o -name shadercache -o -name Backups.backupdb -o -name '.Spotlight-V100' \
		   -o -path "$HOME/Library" -o -path '*/steamapps/common' -o -path '*/windows/system32' \) -prune \
		-o -type f -iname wow.exe -print 2>/dev/null |
	while IFS= read -r f; do
		d=$(dirname "$f")
		is_game "$d" && is_vanilla "$d" && printf '%s\n' "$d"
	done
}

describe() { # one line about a candidate folder
	local d="$1" rl s=""
	rl=$(ci "$d" realmlist.wtf)
	[ -n "$rl" ] && s=$(grep -i -m 1 '^[[:space:]]*set[[:space:]]\{1,\}realmlist' "$rl" 2>/dev/null | tr -d '\r' | awk '{print $3}')
	printf '%s  (%s%s)' "$d" "realmlist ${s:-?}" "$( [ -n "$(ci "$d" vanillafixes.exe)" ] && echo ", VanillaFixes")"
}

find_game() {
	if [ -n "$GAME" ]; then
		local given="$GAME"
		GAME=$(cd "$given" 2>/dev/null && pwd) || { bad "$(t "Klasör yok: $given" "Folder not found: $given")"; return 1; }
		is_game "$GAME" || { bad "$(t "Bu klasörde WoW.exe ve Data yok: $GAME" "No WoW.exe and Data in this folder: $GAME")"; return 1; }
		is_vanilla "$GAME" || { bad "$(t "Bu istemci WoW $(wow_version "$GAME"); OctoLogin 1.12.1 içindir." \
			"This client is WoW $(wow_version "$GAME"); OctoLogin is for 1.12.1.")"; return 1; }
		return 0
	fi
	if is_game "$PWD" && is_vanilla "$PWD"; then GAME="$PWD"; return 0; fi

	local list
	list=$(running_games | while IFS= read -r d; do is_game "$d" && is_vanilla "$d" && printf '%s\n' "$d"; done | sort -u)
	if [ -z "$list" ]; then
		info "$(t "Oyun klasörü aranıyor..." "Looking for the game folder...")"
		list=$(search_games | sort -u)
	fi
	local n
	n=$(printf '%s' "$list" | grep -c . || true)
	if [ "$n" -eq 0 ]; then
		local typed
		typed=$(ask "$(t "Oyun klasörü bulunamadı. WoW.exe'nin olduğu klasörün yolunu yaz: " "Game folder not found. Type the path of the folder with WoW.exe: ")") || typed=""
		typed="${typed%\"}"; typed="${typed#\"}"; typed="${typed%\'}"; typed="${typed#\'}"
		if [ -n "$typed" ] && is_game "$typed"; then GAME="$typed"; find_game; return; fi
		bad "$(t "Oyun klasörü bulunamadı. Klasörü kendin ver: ... | bash -s -- \"/oyun/klasörü\"" \
			"Game folder not found. Give it yourself: ... | bash -s -- \"/path/to/game\"")"
		return 1
	fi
	if [ "$n" -eq 1 ]; then
		GAME="$list"
		return 0
	fi
	echo
	echo "  $(t "Birden fazla oyun klasörü bulundu:" "More than one game folder found:")"
	local i=1 d
	while IFS= read -r d; do printf '    %d) %s\n' "$i" "$(describe "$d")"; i=$((i + 1)); done <<<"$list"
	local pick
	pick=$(ask "  $(t "Hangisi? (numara): " "Which one? (number): ")") || pick=""
	case "$pick" in ''|*[!0-9]*) pick=0 ;; esac
	if [ "$pick" -lt 1 ] || [ "$pick" -gt "$n" ]; then
		bad "$(t "Seçim yapılmadı. Klasörü kendin ver: ... | bash -s -- \"/oyun/klasörü\"" \
			"Nothing chosen. Give the folder yourself: ... | bash -s -- \"/path/to/game\"")"
		return 1
	fi
	GAME=$(printf '%s\n' "$list" | sed -n "${pick}p")
}

# ------------------------------------------------------------------ latest release
REL_TAG="" REL_SHA="" REL_URL="https://github.com/$REPO/releases/latest/download/OctoLogin.dll"

final_url() { # where a URL redirects to
	if command -v curl >/dev/null 2>&1; then curl -fsSL -o /dev/null -w '%{url_effective}' "$1" 2>/dev/null
	else wget -S -O /dev/null "$1" 2>&1 | sed -n 's/^ *Location: *//p' | tail -n 1 | tr -d '\r'; fi
}

latest_release() {
	local json html
	if json=$(fetch "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null); then
		REL_TAG=$(printf '%s' "$json" | tr ',' '\n' | sed -n 's/^[[:space:]]*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
		# The fields of an asset follow its name: digest, then browser_download_url.
		REL_SHA=$(printf '%s' "$json" | tr ',{}' '\n\n\n' | awk '
			/"name":[ ]*"OctoLogin\.dll"/ { inside = 1; next }
			inside && /"name":/ { inside = 0 }
			inside && /"digest":/ { if (match($0, /sha256:[0-9a-f]+/)) print substr($0, RSTART + 7, RLENGTH - 7); exit }')
	fi
	# The API allows 60 requests an hour per IP; the release pages have no such limit.
	if [ -z "$REL_TAG" ]; then
		REL_TAG=$(final_url "https://github.com/$REPO/releases/latest" | sed -n 's#.*/releases/tag/##p')
	fi
	if [ -n "$REL_TAG" ] && [ -z "$REL_SHA" ] &&
		html=$(fetch "https://github.com/$REPO/releases/expanded_assets/$REL_TAG" 2>/dev/null); then
		REL_SHA=$(printf '%s' "$html" | grep -o -E 'OctoLogin\.dll|sha256:[0-9a-f]{64}' |
			awk '/OctoLogin/ { seen = 1; next } seen { print substr($0, 8); exit }')
	fi
	[ -n "$REL_TAG" ] && REL_URL="https://github.com/$REPO/releases/download/$REL_TAG/OctoLogin.dll"
	[ -n "$REL_TAG" ]
}

# ------------------------------------------------------------------ steps
check_loader() {
	step "$(t "DLL yükleyici (VanillaFixes)" "DLL loader (VanillaFixes)")"
	if [ -n "$(ci "$GAME" vanillafixes.exe)" ] && [ -n "$(ci "$GAME" vfpatcher.dll)" ]; then
		ok "$(t "VanillaFixes var" "VanillaFixes is there")"
	else
		bad "$(t "VanillaFixes yok: OctoLogin onsuz yüklenmez." "VanillaFixes is missing: OctoLogin is not loaded without it.")"
		info "$(t "Oyun klasörüne kur: https://github.com/hannesmann/vanillafixes/releases" \
			"Install it into the game folder: https://github.com/hannesmann/vanillafixes/releases")"
	fi
}

check_running() {
	[ "$MODE" = check ] && return 0
	[ -n "$(running_games | while IFS= read -r d; do [ "$d" -ef "$GAME" ] && echo y; done)" ] || return 0
	ask "$(t "  Oyun açık. Oyunu kapatıp Enter'a bas... " "  The game is running. Close it and press Enter... ")" >/dev/null || true
	if [ -n "$(running_games | while IFS= read -r d; do [ "$d" -ef "$GAME" ] && echo y; done)" ]; then
		bad "$(t "Oyun hâlâ açık; kapatıp yeniden çalıştır." "The game is still running; close it and run this again.")"
		return 1
	fi
}

MODS="" DLL=""
check_dll() {
	step "OctoLogin.dll"
	MODS=$(ci "$GAME" mods)
	[ -n "$MODS" ] || MODS="$GAME/mods"
	DLL=$(ci "$MODS" octologin.dll)
	[ -n "$DLL" ] || DLL="$MODS/OctoLogin.dll"

	if ! latest_release; then
		warn "$(t "GitHub'a ulaşılamadı; son sürüm kontrol edilemedi." "Could not reach GitHub; the latest version was not checked.")"
	fi
	local have=""
	[ -f "$DLL" ] && have=$(sha256 "$DLL")

	if [ -n "$have" ] && [ -n "$REL_SHA" ] && [ "$have" = "$REL_SHA" ]; then
		ok "$(t "Kurulu ve güncel ($REL_TAG): $(rel "$DLL")" "Installed and up to date ($REL_TAG): $(rel "$DLL")")"
		return 0
	fi
	if [ -n "$have" ] && [ -z "$REL_SHA" ]; then
		ok "$(t "Kurulu: $(rel "$DLL")" "Installed: $(rel "$DLL")")"
		return 0
	fi
	if [ "$MODE" = check ]; then
		if [ -n "$have" ]; then warn "$(t "Kurulu ama güncel değil (son sürüm $REL_TAG)." "Installed but not the latest ($REL_TAG).")"
		else bad "$(t "Kurulu değil: $(rel "$DLL") yok." "Not installed: no $(rel "$DLL").")"; fi
		return 0
	fi

	mkdir -p "$MODS" || { bad "$(t "Klasör oluşturulamadı: $(rel "$MODS")" "Could not create $(rel "$MODS")")"; return 1; }
	local tmp="$MODS/.OctoLogin.dll.download"
	rm -f "$tmp"
	if ! fetch "$REL_URL" "$tmp"; then
		rm -f "$tmp"
		bad "$(t "İndirilemedi: $REL_URL" "Download failed: $REL_URL")"
		return 1
	fi
	if [ -n "$REL_SHA" ]; then
		if [ "$(sha256 "$tmp")" != "$REL_SHA" ]; then
			rm -f "$tmp"
			bad "$(t "İndirilen dosya bozuk (SHA-256 tutmuyor); tekrar dene." "The download is damaged (SHA-256 mismatch); try again.")"
			return 1
		fi
	elif [ "$(head -c 2 "$tmp")" != MZ ]; then
		rm -f "$tmp"
		bad "$(t "İndirilen dosya bir DLL değil." "The download is not a DLL.")"
		return 1
	fi
	if ! mv -f "$tmp" "$DLL"; then
		rm -f "$tmp"
		bad "$(t "Yazılamadı: $(rel "$DLL")" "Could not write $(rel "$DLL")")"
		return 1
	fi
	if [ -n "$have" ]; then ok "$(t "Güncellendi (${REL_TAG:-son sürüm}): $(rel "$DLL")" "Updated (${REL_TAG:-latest}): $(rel "$DLL")")"
	else ok "$(t "Kuruldu (${REL_TAG:-son sürüm}): $(rel "$DLL")" "Installed (${REL_TAG:-latest}): $(rel "$DLL")")"; fi
	[ -n "$REL_SHA" ] && info "SHA-256 $REL_SHA"
}

check_dllstxt() {
	step "dlls.txt"
	local f
	f=$(ci "$GAME" dlls.txt)
	if [ -z "$f" ]; then
		if [ "$MODE" = check ]; then bad "$(t "dlls.txt yok." "There is no dlls.txt.")"; return 0; fi
		printf '%s\n' "$LINE" >"$GAME/dlls.txt" || { bad "$(t "dlls.txt yazılamadı." "Could not write dlls.txt.")"; return 1; }
		ok "$(t "dlls.txt oluşturuldu: $LINE" "Created dlls.txt: $LINE")"
		return 0
	fi

	local head3 enc="" fixed="" lines canon=0 other=0
	head3=$(head -c 3 "$f" | od -An -tx1 | tr -d ' \n')
	case "$head3" in
		fffe*|feff*) enc=utf16 ;;
		efbbbf) enc=bom ;;
	esac
	local work
	work=$(mktemp "${TMPDIR:-/tmp}/octologin.XXXXXX") || return 1
	case "$enc" in
		utf16) iconv -f UTF-16 -t UTF-8 "$f" >"$work" 2>/dev/null || cp "$f" "$work" ;;
		bom) tail -c +4 "$f" >"$work" ;;
		*) cp "$f" "$work" ;;
	esac
	if [ "$MODE" = check ]; then
		[ "$enc" = utf16 ] && bad "$(t "dlls.txt UTF-16 (\"Unicode\") kaydedilmiş; VanillaFixes hiçbir satırını okuyamaz." \
			"dlls.txt is saved as UTF-16 (\"Unicode\"); VanillaFixes cannot read any line of it.")"
		[ "$enc" = bom ] && bad "$(t "dlls.txt başında BOM var; VanillaFixes ilk satırını okuyamaz." \
			"dlls.txt starts with a BOM; VanillaFixes cannot read its first line.")"
	fi

	lines=$(octo_lines "$work")
	if [ -n "$lines" ]; then
		while IFS=$'\t' read -r num text; do
			if [ "$(printf '%s' "$text" | tr 'A-Z\\' 'a-z/')" = "$(printf '%s' "$LINE" | tr 'A-Z' 'a-z')" ]; then
				canon=$((canon + 1))
			else
				other=$((other + 1))
				[ "$MODE" = check ] && warn "$(t "dlls.txt satır $num yanlış yeri gösteriyor: $text" "dlls.txt line $num points to the wrong place: $text")"
			fi
		done <<<"$lines"
	fi

	if [ "$MODE" = check ]; then
		if [ "$canon" -gt 0 ]; then ok "$(t "Satır var: $LINE" "Line is there: $LINE")"
		else bad "$(t "dlls.txt'de \"$LINE\" satırı yok." "dlls.txt has no \"$LINE\" line.")"; fi
		rm -f "$work"
		return 0
	fi

	if [ -z "$enc" ] && [ "$canon" -eq 1 ] && [ "$other" -eq 0 ]; then
		ok "$(t "Satır var: $LINE" "Line is there: $LINE")"
		rm -f "$work"
		return 0
	fi

	# Rewrite: keep every other line as it is, drop wrong or repeated OctoLogin lines, add ours.
	local crlf=0 out
	grep -q $'\r$' "$work" && crlf=1
	out=$(mktemp "${TMPDIR:-/tmp}/octologin.XXXXXX") || return 1
	awk -v want="$(printf '%s' "$LINE" | tr 'A-Z' 'a-z')" -v line="$LINE" -v crlf="$crlf" '
		BEGIN { eol = crlf ? "\r\n" : "\n" }
		{ l = $0; sub(/\r$/, "", l); t = l; gsub(/^ +| +$/, "", t); k = tolower(t); gsub(/\\/, "/", k)
		  if (substr(l, 1, 1) != "#" && k ~ /(^|\/)octologin\.dll$/) {
		      if (k == want && !done) { printf "%s%s", line, eol; done = 1 }
		      next
		  }
		  printf "%s%s", l, eol }
		END { if (!done) printf "%s%s", line, eol }' "$work" >"$out"
	rm -f "$work"
	if ! cp "$f" "$f.octologin-backup" || ! cat "$out" >"$f"; then
		rm -f "$out"
		bad "$(t "dlls.txt yazılamadı." "Could not write dlls.txt.")"
		return 1
	fi
	rm -f "$out"
	[ "$other" -gt 0 ] && fixed="$(t "yanlış OctoLogin satırları kaldırıldı" "wrong OctoLogin lines removed")"
	[ "$canon" -gt 1 ] && fixed="${fixed:+$fixed, }$(t "tekrar eden satır kaldırıldı" "repeated line removed")"
	[ "$enc" = utf16 ] && fixed="${fixed:+$fixed, }$(t "UTF-16'dan UTF-8'e çevrildi" "converted from UTF-16 to UTF-8")"
	[ "$enc" = bom ] && fixed="${fixed:+$fixed, }$(t "baştaki BOM silindi" "BOM removed")"
	[ "$canon" -eq 0 ] && fixed="${fixed:+$fixed, }$(t "satır eklendi: $LINE" "line added: $LINE")"
	ok "$(t "dlls.txt düzeltildi: $fixed" "dlls.txt fixed: $fixed")"
	info "$(t "Eski hâli: $(rel "$f").octologin-backup" "Old version: $(rel "$f").octologin-backup")"
	return 0
}

check_settings() {
	step "$(t "Ayarlar" "Settings")"
	local rl s ini
	rl=$(ci "$GAME" realmlist.wtf)
	s=""
	[ -n "$rl" ] && s=$(grep -i '^[[:space:]]*set[[:space:]]\{1,\}realmlist' "$rl" 2>/dev/null | tail -n 1 | tr -d '\r' | awk '{print $3}')
	case "$s" in
		127.*|localhost)
			warn "$(t "realmlist $s: yerel proxy (octoproxy) kullanılıyor; OctoLogin bu durumda devreye girmez." \
				"realmlist $s: a local proxy (octoproxy) is used; OctoLogin stays out of the way then.")"
			info "$(t "OctoLogin'i kullanmak için realmlist'i OctoWoW adresine (ör. play.octowow.st) çevir." \
				"To use OctoLogin, set the realmlist to an OctoWoW address (such as play.octowow.st).")" ;;
		"") warn "$(t "realmlist.wtf'de realmlist satırı bulunamadı." "No realmlist line in realmlist.wtf.")" ;;
		*) ok "realmlist $s" ;;
	esac
	ini=$(ci "${MODS:-$GAME/mods}" octologin.ini)
	if [ -n "$ini" ] && grep -q -i '^[[:space:]]*enabled[[:space:]]*=[[:space:]]*0' "$ini"; then
		warn "$(t "OctoLogin.ini'de enabled=0: OctoLogin kapalı." "enabled=0 in OctoLogin.ini: OctoLogin is turned off.")"
	fi
}

# Wine front ends that start WoW.exe directly skip VanillaFixes, and with it every mod.
check_launchers() {
	[ "$(uname)" = Linux ] || return 0
	local f hit=""
	for f in "$HOME"/.config/lutris/games/*.yml "$HOME"/.local/share/lutris/games/*.yml \
		"$HOME"/.var/app/net.lutris.Lutris/config/lutris/games/*.yml \
		"$HOME"/.var/app/net.lutris.Lutris/data/lutris/games/*.yml; do
		[ -f "$f" ] || continue
		if grep -q -i '^[[:space:]]*exe:.*wow\.exe[[:space:]"'\'']*$' "$f"; then
			warn "$(t "Lutris oyunu doğrudan WoW.exe ile başlatıyor; bu şekilde modlar yüklenmez: $f" \
				"Lutris starts WoW.exe directly, which loads no mods: $f")"
			info "$(t "Lutris'te oyunu yapılandır > Oyun seçenekleri > Çalıştırılabilir: VanillaFixes.exe" \
				"In Lutris: Configure > Game options > Executable: VanillaFixes.exe")"
			hit=1
		fi
	done
	for f in "$HOME"/.steam/steam/userdata/*/config/shortcuts.vdf "$HOME"/.local/share/Steam/userdata/*/config/shortcuts.vdf \
		"$HOME"/.var/app/com.valvesoftware.Steam/.local/share/Steam/userdata/*/config/shortcuts.vdf; do
		[ -f "$f" ] || continue
		if LC_ALL=C grep -a -i -q 'wow\.exe"' "$f"; then
			warn "$(t "Steam'deki oyun kısayolu WoW.exe'yi başlatıyor; bu şekilde modlar yüklenmez." \
				"A Steam shortcut starts WoW.exe, which loads no mods.")"
			info "$(t "Kısayolun hedefini VanillaFixes.exe yap." "Point the shortcut at VanillaFixes.exe instead.")"
			hit=1
			break
		fi
	done
	[ -n "$hit" ] || true
}

check_log() {
	step "$(t "Oyunda çalışıyor mu (OctoLogin.log)" "Running in the game (OctoLogin.log)")"
	local log start_line start_no when ver
	log=$(ci "${MODS:-$GAME/mods}" octologin.log)
	if [ -z "$log" ]; then
		if [ "$MODE" = check ]; then
			warn "$(t "OctoLogin hiç çalışmamış (log yok)." "OctoLogin has never run (no log).")"
			info "$(t "Oyunu VanillaFixes.exe (ya da OctoWoW launcher) ile başlattığından emin ol." \
				"Make sure the game is started with VanillaFixes.exe (or the OctoWoW launcher).")"
		else
			info "$(t "Henüz çalışmadı (normal). Oyunu açıp giriş yaptıktan sonra kontrol için: --check" \
				"Not run yet (normal). To check after starting the game and logging in: --check")"
		fi
		return 0
	fi
	when=$(datestr "$(mtime "$log")")
	start_no=$(grep -n -E '^[0-9:]+ OctoLogin [^ ]+: ' "$log" | tail -n 1 | cut -d: -f1)
	if [ -z "$start_no" ]; then
		warn "$(t "Log'da başlangıç satırı yok." "No start line in the log.")"
		return 0
	fi
	start_line=$(sed -n "${start_no}p" "$log" | tr -d '\r')
	ver=$(printf '%s' "$start_line" | sed -n 's/^[0-9:]* OctoLogin \([^:]*\): .*/\1/p')
	case "$start_line" in
		*": ready"|*": ready "*)
			ok "$(t "Oyunda yüklendi: OctoLogin $ver (son çalışma $when)" "Loaded in the game: OctoLogin $ver (last run $when)")"
			if [ -n "$REL_TAG" ] && [ "v$ver" != "$REL_TAG" ] && [ "$ver" != "$REL_TAG" ]; then
				info "$(t "Son çalışan sürüm $ver; yeni sürüm ($REL_TAG) oyunu yeniden başlatınca yüklenir." \
					"The last run used $ver; the new one ($REL_TAG) loads when the game starts again.")"
			fi ;;
		*"not WoW 1.12.1"*)
			bad "$(t "Oyun istemcisi WoW 1.12.1 (5875) değil; OctoLogin çalışamaz." "The game client is not WoW 1.12.1 (5875); OctoLogin cannot work.")" ;;
		*"already changed by another mod"*)
			bad "$(t "Başka bir mod oyunun connect'ini değiştiriyor (başka bir login/proxy modu?); OctoLogin devre dışı kaldı." \
				"Another mod changes the game's connect (another login/proxy mod?); OctoLogin stayed off.")"
			info "$(t "dlls.txt'de OctoLogin'den önceki modlardan birini kaldırıp dene." "Remove such a mod listed before OctoLogin in dlls.txt.")" ;;
		*) warn "$start_line" ;;
	esac
	if [ -f "$DLL" ] && [ "$(mtime "$DLL")" -gt "$(mtime "$log")" ]; then
		info "$(t "Bu bilgiler şimdi kurulan DLL'den önceki çalışmaya ait; oyunu başlatınca yenilenir." \
			"This is from a run before the DLL now installed; it renews when the game starts.")"
	fi
	case "$start_line" in *": ready"|*": ready "*) ;; *) return 0 ;; esac
	local rest
	rest=$(tail -n "+$((start_no + 1))" "$log" | tr -d '\r')
	case "$rest" in
		*": local proxy, left alone"*)
			warn "$(t "Son girişte realmlist yerel proxy'ydi (127.0.0.1); OctoLogin karışmadı." \
				"The last login used a local proxy (127.0.0.1); OctoLogin stayed out.")" ;;
		*": not an OctoWoW address, left alone"*)
			warn "$(t "Son girişte realmlist OctoWoW adresi değildi; OctoLogin karışmadı." \
				"The last login was not to an OctoWoW address; OctoLogin stayed out.")" ;;
	esac
	local l
	l=$(printf '%s\n' "$rest" | grep -E '^[0-9:]+ login: ' | tail -n 1)
	case "$l" in
		*"answered first"*) ok "$(t "Son giriş:" "Last login:") ${l#* login: }" ;;
		"") [ -n "$rest" ] || info "$(t "O çalışmada giriş yapılmamış." "No login during that run.")" ;;
		*) warn "$(t "Son giriş:" "Last login:") ${l#* login: }" ;;
	esac
	printf '%s\n' "$rest" | grep -E '^[0-9:]+ world [^ ]' | grep -v -E '^[0-9:]+ world [0-9.]+:' |
		grep -v ': testing ' | tail -n 6 | while IFS= read -r l; do info "${l#* }"; done
}

uninstall() {
	step "$(t "Kaldırma" "Uninstall")"
	local f lines mods
	f=$(ci "$GAME" dlls.txt)
	if [ -n "$f" ] && [ -n "$(octo_lines "$f")" ]; then
		local out crlf=0
		grep -q $'\r$' "$f" && crlf=1
		out=$(mktemp "${TMPDIR:-/tmp}/octologin.XXXXXX") || return 1
		awk -v crlf="$crlf" 'BEGIN { eol = crlf ? "\r\n" : "\n" }
			{ l = $0; sub(/\r$/, "", l); t = l; gsub(/^ +| +$/, "", t); k = tolower(t); gsub(/\\/, "/", k)
			  if (substr(l, 1, 1) != "#" && k ~ /(^|\/)octologin\.dll$/) next
			  printf "%s%s", l, eol }' "$f" >"$out"
		cp "$f" "$f.octologin-backup" && cat "$out" >"$f" && ok "$(t "dlls.txt'den çıkarıldı" "Removed from dlls.txt")"
		rm -f "$out"
	else
		ok "$(t "dlls.txt'de OctoLogin yok" "Not in dlls.txt")"
	fi
	mods=$(ci "$GAME" mods)
	local x n=0
	for x in octologin.dll octologin.ini octologin.log; do
		f=$(ci "${mods:-$GAME/mods}" "$x")
		[ -n "$f" ] && rm -f "$f" && n=$((n + 1))
	done
	ok "$(t "mods klasöründen $n dosya silindi" "$n files deleted from mods")"
}

# ------------------------------------------------------------------ main
case "$MODE" in
	install) printf '%sOctoLogin %s%s\n' "$B" "$(t "kurulum" "setup")" "$N" ;;
	check) printf '%sOctoLogin %s%s\n' "$B" "$(t "kontrol" "check")" "$N" ;;
	uninstall) printf '%sOctoLogin %s%s\n' "$B" "$(t "kaldırma" "uninstall")" "$N" ;;
esac

step "$(t "Oyun klasörü" "Game folder")"
find_game || exit 1
ok "$GAME"

if [ "$MODE" = uninstall ]; then
	check_running || exit 1
	uninstall
	echo
	exit 0
fi

check_loader
check_running || exit 1
check_dll
check_dllstxt
check_settings
check_launchers
check_log

echo
if [ "$PROBLEMS" -gt 0 ]; then
	printf '%s%s%s\n' "$R" "$(t "$PROBLEMS sorun var; yukarıdaki [ XX ] satırlarına bak." "$PROBLEMS problem(s); see the [ XX ] lines above.")" "$N"
	exit 1
fi
if [ "$MODE" = install ]; then
	if [ "$WARNINGS" -gt 0 ]; then
		printf '%s%s%s\n' "$Y" "$(t "Kuruldu; [ !! ] satırlarına bir bak." "Installed; have a look at the [ !! ] lines.")" "$N"
	else
		printf '%s%s%s\n' "$G" "$(t "Hazır." "Ready.")" "$N"
	fi
	t "Oyunu VanillaFixes.exe (ya da OctoWoW launcher) ile başlat. VanillaFixes \"will load additional DLLs\"
diye sorarsa OK'e bas. Girişten sonra kontrol için bu komutu --check ile çalıştır.
" "Start the game with VanillaFixes.exe (or the OctoWoW launcher). If VanillaFixes says it \"will load
additional DLLs\", press OK. To check after logging in, run this again with --check.
"
else
	if [ "$WARNINGS" -gt 0 ]; then
		printf '%s%s%s\n' "$Y" "$(t "Engel yok; [ !! ] satırlarına bir bak." "Nothing blocking; have a look at the [ !! ] lines.")" "$N"
	else
		printf '%s%s%s\n' "$G" "$(t "Sorun yok." "No problems found.")" "$N"
	fi
fi
exit 0
