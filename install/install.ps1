# OctoLogin installer and checker for Windows.
#
#   irm https://raw.githubusercontent.com/fmustafayaman/OctoLogin/main/install/install.ps1 | iex
#
# Options:
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/fmustafayaman/OctoLogin/main/install/install.ps1))) -Check
#   -Check          only check, change nothing
#   -Uninstall      remove OctoLogin
#   -Game <folder>  the game folder (the one with WoW.exe); found automatically if left out
#
# Installs the latest release into <game>\mods, adds it to dlls.txt, fixes what it can and
# reports what it cannot. Running it again is safe: it only changes what is wrong.
# Works in Windows PowerShell 5.1 and PowerShell 7.

param([switch]$Check, [switch]$Uninstall, [string]$Game = '')

# Everything runs in its own scope: "irm | iex" must not leave variables or settings behind.
& {
param([bool]$Check, [bool]$Uninstall, [string]$Game)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch { }

$Repo = 'fmustafayaman/OctoLogin'
$Line = 'mods/OctoLogin.dll'
$Mode = if ($Uninstall) { 'uninstall' } elseif ($Check) { 'check' } else { 'install' }

# ------------------------------------------------------------------ output
$lc = $env:OCTOLOGIN_LANG
if (-not $lc) { $lc = (Get-UICulture).Name + ' ' + (Get-Culture).Name }
$UseTr = $lc -match '(^| )tr'
function T([string]$tr, [string]$en) { if ($UseTr) { $tr } else { $en } }

$st = @{ Problems = 0; Warnings = 0 }
$ctx = @{ GameDir = ''; Mods = ''; Dll = '' }
function Ok([string]$m)   { Write-Host '  [ OK ] ' -ForegroundColor Green -NoNewline; Write-Host $m }
function Warn([string]$m) { Write-Host '  [ !! ] ' -ForegroundColor Yellow -NoNewline; Write-Host $m; $st.Warnings++ }
function Bad([string]$m)  { Write-Host '  [ XX ] ' -ForegroundColor Red -NoNewline; Write-Host $m; $st.Problems++ }
function Info([string]$m) { Write-Host "         $m" }
function Step([string]$m) { Write-Host ''; Write-Host $m -ForegroundColor White }

# ------------------------------------------------------------------ helpers
# The file in $dir whose name is $name, ignoring case (or $null).
function Ci([string]$dir, [string]$name) {
	$p = Join-Path $dir $name
	if (Test-Path -LiteralPath $p) { return (Get-Item -LiteralPath $p -Force).FullName }
	return $null
}
function Rel([string]$p) { if ($p.StartsWith($ctx.GameDir + [IO.Path]::DirectorySeparatorChar)) { $p.Substring($ctx.GameDir.Length + 1) } else { $p } }
function Sha([string]$p) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant() }

function Test-Game([string]$d) {
	if (-not $d) { return $false }
	try { [IO.File]::Exists((Join-Path $d 'WoW.exe')) -and [IO.Directory]::Exists((Join-Path $d 'Data')) } catch { $false }
}
# "1.12.1.5875" from the version resource of WoW.exe (empty if it has none).
function Get-WowVersion([string]$d) {
	try { $v = (Get-Item -LiteralPath (Join-Path $d 'WoW.exe')).VersionInfo.FileVersion } catch { return '' }
	if (-not $v) { return '' }
	(($v -replace ',\s*', '.') -replace '\s', '').Trim('.')
}
function Test-Vanilla([string]$d) { $v = Get-WowVersion $d; (-not $v) -or $v.StartsWith('1.12') }

function Get-Realmlist([string]$d) {
	$f = Ci $d 'realmlist.wtf'
	if (-not $f) { return '' }
	$m = Select-String -LiteralPath $f -Pattern '^\s*set\s+realmlist\s+(\S+)' | Select-Object -Last 1
	if ($m) { $m.Matches[0].Groups[1].Value } else { '' }
}

# Lines of dlls.txt that load an OctoLogin.dll (not commented out).
function Test-OctoLine([string]$l) {
	if ($l.StartsWith('#')) { return $false }
	$k = $l.Trim(' ').ToLowerInvariant().Replace('\', '/')
	$k -match '(^|/)octologin\.dll$'
}
function Test-Canonical([string]$l) { $l.Trim(' ').ToLowerInvariant().Replace('\', '/') -eq $Line.ToLowerInvariant() }

# dlls.txt as lines, with what is wrong about its encoding.
function Read-DllsTxt([string]$f) {
	$b = [IO.File]::ReadAllBytes($f)
	$enc = ''
	if ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) { $enc = 'utf16'; $text = [Text.Encoding]::Unicode.GetString($b, 2, $b.Length - 2) }
	elseif ($b.Length -ge 2 -and $b[0] -eq 0xFE -and $b[1] -eq 0xFF) { $enc = 'utf16'; $text = [Text.Encoding]::BigEndianUnicode.GetString($b, 2, $b.Length - 2) }
	elseif ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { $enc = 'bom'; $text = [Text.Encoding]::UTF8.GetString($b, 3, $b.Length - 3) }
	else { $text = [Text.Encoding]::UTF8.GetString($b) }
	$lines = @($text -split "`n" | ForEach-Object { $_.TrimEnd("`r") })
	if ($lines.Count -gt 0 -and $lines[-1] -eq '') { $lines = @($lines | Select-Object -First ($lines.Count - 1)) }
	$crlf = ($text -match "`r`n") -or ($text.Length -eq 0)
	@{ Lines = $lines; Enc = $enc; Crlf = $crlf }
}
function Write-DllsTxt([string]$f, [string[]]$lines, [bool]$crlf) {
	$eol = if ($crlf) { "`r`n" } else { "`n" }
	$text = ''
	foreach ($l in $lines) { $text += $l + $eol }
	# UTF-8 without a BOM: VanillaFixes would read a BOM as part of the first line.
	[IO.File]::WriteAllText($f, $text, (New-Object Text.UTF8Encoding $false))
}

# ------------------------------------------------------------------ find the game folder
function Get-RunningGames {
	Get-Process -Name WoW, VanillaFixes -ErrorAction SilentlyContinue | ForEach-Object {
		try { if ($_.Path) { Split-Path -Parent $_.Path } } catch { }
	}
}

function Find-Games {
	$skip = @('Windows', 'ProgramData', '$Recycle.Bin', 'System Volume Information', 'Recovery', 'PerfLogs',
		'node_modules', '.git', 'AppData', 'WinSxS', 'Microsoft', 'Packages', 'steamapps', 'Temp')
	$queue = New-Object System.Collections.Generic.Queue[psobject]
	foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
		if ($d.Root -and (Test-Path -LiteralPath $d.Root)) { $queue.Enqueue([pscustomobject]@{ Dir = [string]$d.Root; Depth = 3 }) }
	}
	foreach ($p in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:USERPROFILE, $env:LOCALAPPDATA, $env:APPDATA,
		[Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('MyDocuments'))) {
		if ($p -and (Test-Path -LiteralPath $p)) { $queue.Enqueue([pscustomobject]@{ Dir = [string]$p; Depth = 4 }) }
	}
	$seen = @{}
	$found = New-Object System.Collections.Generic.List[string]
	while ($queue.Count -gt 0) {
		$item = $queue.Dequeue()
		$dir = $item.Dir
		$key = $dir.TrimEnd('\', '/').ToLowerInvariant()
		if ($seen.ContainsKey($key)) { continue }
		$seen[$key] = $true
		if ((Test-Game $dir) -and (Test-Vanilla $dir)) { $found.Add($dir.TrimEnd('\', '/')); continue }
		if ($item.Depth -le 0) { continue }
		try { $subs = [IO.Directory]::GetDirectories($dir) } catch { continue }
		foreach ($s in $subs) {
			$name = [IO.Path]::GetFileName($s)
			if ($skip -contains $name) { continue }
			try { if (([IO.File]::GetAttributes($s) -band [IO.FileAttributes]::ReparsePoint)) { continue } } catch { continue }
			$queue.Enqueue([pscustomobject]@{ Dir = $s; Depth = $item.Depth - 1 })
		}
	}
	$found | Sort-Object -Unique
}

function Select-Folder {
	try {
		Add-Type -AssemblyName System.Windows.Forms
		$dlg = New-Object System.Windows.Forms.FolderBrowserDialog
		$dlg.Description = T "OctoWoW oyun klasörünü seç (WoW.exe'nin olduğu klasör)" 'Choose the OctoWoW game folder (the one with WoW.exe)'
		$dlg.ShowNewFolderButton = $false
		if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
		return ''
	} catch {
		return (Read-Host (T "WoW.exe'nin olduğu klasörün yolunu yaz" 'Type the path of the folder with WoW.exe')).Trim('"', ' ')
	}
}

function Resolve-GameDir {
	if ($Game) {
		$g = $Game.Trim('"', ' ')
		if (-not (Test-Path -LiteralPath $g -PathType Container)) { Bad (T "Klasör yok: $g" "Folder not found: $g"); return $null }
		$g = (Resolve-Path -LiteralPath $g).ProviderPath.TrimEnd('\')
		if (-not (Test-Game $g)) { Bad (T "Bu klasörde WoW.exe ve Data yok: $g" "No WoW.exe and Data in this folder: $g"); return $null }
		if (-not (Test-Vanilla $g)) {
			Bad (T "Bu istemci WoW $(Get-WowVersion $g); OctoLogin 1.12.1 içindir." "This client is WoW $(Get-WowVersion $g); OctoLogin is for 1.12.1.")
			return $null
		}
		return $g
	}
	foreach ($d in @($env:OCTOLOGIN_DIR, (Get-Location).ProviderPath)) {
		if ($d -and (Test-Game $d) -and (Test-Vanilla $d)) { return (Resolve-Path -LiteralPath $d).ProviderPath.TrimEnd('\') }
	}
	$list = @(Get-RunningGames | Where-Object { (Test-Game $_) -and (Test-Vanilla $_) } | Sort-Object -Unique)
	if ($list.Count -eq 0) {
		Info (T 'Oyun klasörü aranıyor...' 'Looking for the game folder...')
		$list = @(Find-Games)
	}
	if ($list.Count -eq 1) { return $list[0] }
	if ($list.Count -eq 0) {
		Info (T 'Bulunamadı; klasörü seç.' 'Not found; choose the folder.')
		$g = Select-Folder
		if ($g) { return (Resolve-GameDirFrom $g) }
		Bad (T 'Oyun klasörü bulunamadı. Klasörü kendin ver: -Game "D:\Oyunlar\OctoWoW"' 'Game folder not found. Give it yourself: -Game "D:\Games\OctoWoW"')
		return $null
	}
	Write-Host ''
	Write-Host ('  ' + (T 'Birden fazla oyun klasörü bulundu:' 'More than one game folder found:'))
	for ($i = 0; $i -lt $list.Count; $i++) {
		$d = $list[$i]
		$vf = if (Ci $d 'VanillaFixes.exe') { ', VanillaFixes' } else { '' }
		$rl = Get-Realmlist $d
		if (-not $rl) { $rl = '?' }
		Write-Host ("    {0}) {1}  (realmlist {2}{3})" -f ($i + 1), $d, $rl, $vf)
	}
	$pick = 0
	[void][int]::TryParse((Read-Host ('  ' + (T 'Hangisi? (numara)' 'Which one? (number)'))), [ref]$pick)
	if ($pick -lt 1 -or $pick -gt $list.Count) {
		Bad (T 'Seçim yapılmadı. Klasörü kendin ver: -Game "D:\Oyunlar\OctoWoW"' 'Nothing chosen. Give the folder yourself: -Game "D:\Games\OctoWoW"')
		return $null
	}
	$list[$pick - 1]
}
function Resolve-GameDirFrom([string]$g) { $Game = $g; Resolve-GameDir }

# ------------------------------------------------------------------ steps
function Test-Loader {
	Step (T 'DLL yükleyici (VanillaFixes)' 'DLL loader (VanillaFixes)')
	if ((Ci $ctx.GameDir 'VanillaFixes.exe') -and (Ci $ctx.GameDir 'VfPatcher.dll')) {
		Ok (T 'VanillaFixes var' 'VanillaFixes is there')
	} else {
		Bad (T 'VanillaFixes yok: OctoLogin onsuz yüklenmez.' 'VanillaFixes is missing: OctoLogin is not loaded without it.')
		Info (T 'Oyun klasörüne kur: https://github.com/hannesmann/vanillafixes/releases' 'Install it into the game folder: https://github.com/hannesmann/vanillafixes/releases')
	}
}

function Test-GameClosed {
	if ($Mode -eq 'check') { return $true }
	$running = { @(Get-RunningGames | Where-Object { $_ -and ($_.TrimEnd('\') -eq $ctx.GameDir) }).Count -gt 0 }
	if (-not (& $running)) { return $true }
	[void](Read-Host (T 'Oyun açık. Oyunu kapatıp Enter''a bas' 'The game is running. Close it and press Enter'))
	if (& $running) {
		Bad (T 'Oyun hâlâ açık; kapatıp yeniden çalıştır.' 'The game is still running; close it and run this again.')
		return $false
	}
	$true
}

$rel = @{ Tag = ''; Sha = ''; Url = "https://github.com/$Repo/releases/latest/download/OctoLogin.dll" }
function Get-LatestRelease {
	$ua = @{ 'User-Agent' = 'OctoLogin-installer' }
	try {
		$r = Invoke-RestMethod -UseBasicParsing -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers $ua
		$rel.Tag = [string]$r.tag_name
		$a = $r.assets | Where-Object { $_.name -eq 'OctoLogin.dll' } | Select-Object -First 1
		if ($a -and [string]$a.digest -match '^sha256:([0-9a-f]{64})$') { $rel.Sha = $Matches[1] }
	} catch { }
	# The API allows 60 requests an hour per IP; the release pages have no such limit.
	if (-not $rel.Tag) {
		try {
			$resp = Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/$Repo/releases/latest" -Headers $ua
			$u = if ($resp.BaseResponse.ResponseUri) { $resp.BaseResponse.ResponseUri } else { $resp.BaseResponse.RequestMessage.RequestUri }
			if ([string]$u -match '/releases/tag/([^/?#]+)') { $rel.Tag = $Matches[1] }
		} catch { }
	}
	if ($rel.Tag -and -not $rel.Sha) {
		try {
			$html = (Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/$Repo/releases/expanded_assets/$($rel.Tag)" -Headers $ua).Content
			$i = $html.IndexOf('OctoLogin.dll')
			if ($i -ge 0 -and $html.Substring($i) -match 'sha256:([0-9a-f]{64})') { $rel.Sha = $Matches[1] }
		} catch { }
	}
	if ($rel.Tag) { $rel.Url = "https://github.com/$Repo/releases/download/$($rel.Tag)/OctoLogin.dll" }
	[bool]$rel.Tag
}

function Write-AccessHint {
	Info (T 'Oyun klasörüne yazma izni yok. PowerShell''i "Yönetici olarak çalıştır" ile açıp komutu tekrar çalıştır.' `
		'No permission to write to the game folder. Open PowerShell with "Run as administrator" and run the command again.')
}

function Install-Dll {
	Step 'OctoLogin.dll'
	$ctx.Mods = Ci $ctx.GameDir 'mods'
	if (-not $ctx.Mods) { $ctx.Mods = Join-Path $ctx.GameDir 'mods' }
	$ctx.Dll = Ci $ctx.Mods 'OctoLogin.dll'
	if (-not $ctx.Dll) { $ctx.Dll = Join-Path $ctx.Mods 'OctoLogin.dll' }

	if (-not (Get-LatestRelease)) {
		Warn (T 'GitHub''a ulaşılamadı; son sürüm kontrol edilemedi.' 'Could not reach GitHub; the latest version was not checked.')
	}
	$have = if (Test-Path -LiteralPath $ctx.Dll -PathType Leaf) { Sha $ctx.Dll } else { '' }

	if ($have -and $rel.Sha -and $have -eq $rel.Sha) { Ok (T "Kurulu ve güncel ($($rel.Tag)): $(Rel $ctx.Dll)" "Installed and up to date ($($rel.Tag)): $(Rel $ctx.Dll)"); return }
	if ($have -and -not $rel.Sha) { Ok (T "Kurulu: $(Rel $ctx.Dll)" "Installed: $(Rel $ctx.Dll)"); return }
	if ($Mode -eq 'check') {
		if ($have) { Warn (T "Kurulu ama güncel değil (son sürüm $($rel.Tag))." "Installed but not the latest ($($rel.Tag)).") }
		else { Bad (T "Kurulu değil: $(Rel $ctx.Dll) yok." "Not installed: no $(Rel $ctx.Dll).") }
		return
	}

	$tmp = Join-Path $ctx.Mods '.OctoLogin.dll.download'
	try {
		if (-not (Test-Path -LiteralPath $ctx.Mods)) { [void](New-Item -ItemType Directory -Path $ctx.Mods) }
		Invoke-WebRequest -UseBasicParsing -Uri $rel.Url -OutFile $tmp -Headers @{ 'User-Agent' = 'OctoLogin-installer' }
	} catch [UnauthorizedAccessException] {
		Bad (T "Yazılamadı: $(Rel $ctx.Mods)" "Could not write to $(Rel $ctx.Mods)"); Write-AccessHint; return
	} catch {
		Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
		Bad (T "İndirilemedi: $($rel.Url)" "Download failed: $($rel.Url)"); Info $_.Exception.Message; return
	}
	$bytes = [IO.File]::ReadAllBytes($tmp)
	if ($rel.Sha) {
		if ((Sha $tmp) -ne $rel.Sha) {
			Remove-Item -LiteralPath $tmp -Force
			Bad (T 'İndirilen dosya bozuk (SHA-256 tutmuyor); tekrar dene.' 'The download is damaged (SHA-256 mismatch); try again.'); return
		}
	} elseif ($bytes.Length -lt 2 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) {
		Remove-Item -LiteralPath $tmp -Force
		Bad (T 'İndirilen dosya bir DLL değil.' 'The download is not a DLL.'); return
	}
	try {
		Move-Item -LiteralPath $tmp -Destination $ctx.Dll -Force
	} catch {
		Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
		Bad (T "Yazılamadı: $(Rel $ctx.Dll)" "Could not write $(Rel $ctx.Dll)")
		if ($_.Exception -is [UnauthorizedAccessException]) { Write-AccessHint } else { Info $_.Exception.Message }
		return
	}
	# An antivirus that takes the file away does it within moments of it being written.
	Start-Sleep -Seconds 2
	if (-not (Test-Path -LiteralPath $ctx.Dll -PathType Leaf) -or ($rel.Sha -and (Sha $ctx.Dll) -ne $rel.Sha)) {
		Bad (T 'DLL yazıldıktan hemen sonra silindi: büyük ihtimalle antivirüs karantinaya aldı.' 'The DLL was removed right after it was written: most likely an antivirus quarantined it.')
		Info (T 'OctoLogin 1.1.0 VirusTotal''da 0/71 temiz. Antivirüsün karantinasından geri yükle ya da mods klasörünü istisnaya ekle, sonra tekrar çalıştır.' `
			'OctoLogin 1.1.0 is 0/71 clean on VirusTotal. Restore it from the antivirus quarantine or exclude the mods folder, then run this again.')
		return
	}
	$tag = if ($rel.Tag) { $rel.Tag } else { T 'son sürüm' 'latest' }
	if ($have) { Ok (T "Güncellendi ($tag): $(Rel $ctx.Dll)" "Updated ($tag): $(Rel $ctx.Dll)") }
	else { Ok (T "Kuruldu ($tag): $(Rel $ctx.Dll)" "Installed ($tag): $(Rel $ctx.Dll)") }
	if ($rel.Sha) { Info "SHA-256 $($rel.Sha)" }
}

function Repair-DllsTxt {
	Step 'dlls.txt'
	$f = Ci $ctx.GameDir 'dlls.txt'
	if (-not $f) {
		if ($Mode -eq 'check') { Bad (T 'dlls.txt yok.' 'There is no dlls.txt.'); return }
		try { Write-DllsTxt (Join-Path $ctx.GameDir 'dlls.txt') @($Line) $true }
		catch { Bad (T 'dlls.txt yazılamadı.' 'Could not write dlls.txt.'); Write-AccessHint; return }
		Ok (T "dlls.txt oluşturuldu: $Line" "Created dlls.txt: $Line")
		return
	}
	$d = Read-DllsTxt $f
	$canon = 0; $other = 0
	for ($i = 0; $i -lt $d.Lines.Count; $i++) {
		$l = $d.Lines[$i]
		if (-not (Test-OctoLine $l)) { continue }
		if (Test-Canonical $l) { $canon++ }
		else {
			$other++
			if ($Mode -eq 'check') { Warn (T "dlls.txt satır $($i + 1) yanlış yeri gösteriyor: $($l.Trim())" "dlls.txt line $($i + 1) points to the wrong place: $($l.Trim())") }
		}
	}
	if ($Mode -eq 'check') {
		if ($d.Enc -eq 'utf16') { Bad (T 'dlls.txt UTF-16 ("Unicode") kaydedilmiş; VanillaFixes hiçbir satırını okuyamaz.' 'dlls.txt is saved as UTF-16 ("Unicode"); VanillaFixes cannot read any line of it.') }
		if ($d.Enc -eq 'bom') { Bad (T 'dlls.txt başında BOM var; VanillaFixes ilk satırını okuyamaz.' 'dlls.txt starts with a BOM; VanillaFixes cannot read its first line.') }
		if ($canon -gt 0) { Ok (T "Satır var: $Line" "Line is there: $Line") }
		else { Bad (T "dlls.txt'de `"$Line`" satırı yok." "dlls.txt has no `"$Line`" line.") }
		return
	}
	if (-not $d.Enc -and $canon -eq 1 -and $other -eq 0) { Ok (T "Satır var: $Line" "Line is there: $Line"); return }

	# Rewrite: keep every other line as it is, drop wrong or repeated OctoLogin lines, add ours.
	$out = New-Object System.Collections.Generic.List[string]
	$done = $false
	foreach ($l in $d.Lines) {
		if (Test-OctoLine $l) {
			if ((Test-Canonical $l) -and -not $done) { $out.Add($Line); $done = $true }
			continue
		}
		$out.Add($l)
	}
	if (-not $done) { $out.Add($Line) }
	try {
		Copy-Item -LiteralPath $f -Destination "$f.octologin-backup" -Force
		Write-DllsTxt $f $out.ToArray() $d.Crlf
	} catch {
		Bad (T 'dlls.txt yazılamadı.' 'Could not write dlls.txt.'); Write-AccessHint; return
	}
	$fixed = @()
	if ($other -gt 0) { $fixed += T 'yanlış OctoLogin satırları kaldırıldı' 'wrong OctoLogin lines removed' }
	if ($canon -gt 1) { $fixed += T 'tekrar eden satır kaldırıldı' 'repeated line removed' }
	if ($d.Enc -eq 'utf16') { $fixed += T "UTF-16'dan UTF-8'e çevrildi" 'converted from UTF-16 to UTF-8' }
	if ($d.Enc -eq 'bom') { $fixed += T 'baştaki BOM silindi' 'BOM removed' }
	if ($canon -eq 0) { $fixed += T "satır eklendi: $Line" "line added: $Line" }
	Ok ((T 'dlls.txt düzeltildi: ' 'dlls.txt fixed: ') + ($fixed -join ', '))
	Info (T "Eski hâli: $(Rel $f).octologin-backup" "Old version: $(Rel $f).octologin-backup")
}

function Test-Settings {
	Step (T 'Ayarlar' 'Settings')
	$s = Get-Realmlist $ctx.GameDir
	if ($s -match '^(127\.|localhost$)') {
		Warn (T "realmlist ${s}: yerel proxy (octoproxy) kullanılıyor; OctoLogin bu durumda devreye girmez." "realmlist ${s}: a local proxy (octoproxy) is used; OctoLogin stays out of the way then.")
		Info (T "OctoLogin'i kullanmak için realmlist'i OctoWoW adresine (ör. play.octowow.st) çevir." 'To use OctoLogin, set the realmlist to an OctoWoW address (such as play.octowow.st).')
	} elseif (-not $s) {
		Warn (T "realmlist.wtf'de realmlist satırı bulunamadı." 'No realmlist line in realmlist.wtf.')
	} else { Ok "realmlist $s" }
	$ini = if ($ctx.Mods) { Ci $ctx.Mods 'OctoLogin.ini' } else { $null }
	if ($ini -and (Select-String -LiteralPath $ini -Pattern '^\s*enabled\s*=\s*0' -Quiet)) {
		Warn (T "OctoLogin.ini'de enabled=0: OctoLogin kapalı." 'enabled=0 in OctoLogin.ini: OctoLogin is turned off.')
	}
}

# Starting WoW.exe directly skips VanillaFixes, and with it every mod.
function Test-Launchers {
	$wow = (Join-Path $ctx.GameDir 'WoW.exe').ToLowerInvariant()
	try {
		$sh = New-Object -ComObject WScript.Shell
		$dirs = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('CommonDesktopDirectory'),
			[Environment]::GetFolderPath('StartMenu'), [Environment]::GetFolderPath('CommonStartMenu')) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
		foreach ($lnk in (Get-ChildItem -LiteralPath $dirs -Filter *.lnk -Recurse -Depth 3 -ErrorAction SilentlyContinue)) {
			$target = [string]$sh.CreateShortcut($lnk.FullName).TargetPath
			if ($target.ToLowerInvariant() -eq $wow) {
				Warn (T "Kısayol doğrudan WoW.exe'yi başlatıyor; bu şekilde modlar yüklenmez: $($lnk.Name)" "A shortcut starts WoW.exe directly, which loads no mods: $($lnk.Name)")
				Info (T 'Oyunu VanillaFixes.exe (ya da OctoWoW launcher) ile başlat.' 'Start the game with VanillaFixes.exe (or the OctoWoW launcher).')
			}
		}
	} catch { }
	# Compatibility mode on WoW.exe stops VanillaFixes from starting the game.
	foreach ($k in @('HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers', 'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers')) {
		try {
			$p = Get-ItemProperty -LiteralPath $k -ErrorAction Stop
			foreach ($n in $p.PSObject.Properties.Name) {
				if ($n.ToLowerInvariant() -eq $wow -and ([string]$p.$n) -match 'WIN|VISTA') {
					Warn (T "WoW.exe uyumluluk modunda ($($p.$n)); VanillaFixes oyunu başlatamaz." "WoW.exe runs in compatibility mode ($($p.$n)); VanillaFixes cannot start the game.")
					Info (T 'WoW.exe > Özellikler > Uyumluluk: "Bu programı uyumluluk modunda çalıştır" işaretini kaldır.' 'WoW.exe > Properties > Compatibility: untick "Run this program in compatibility mode".')
				}
			}
		} catch { }
	}
}

function Test-Log {
	Step (T 'Oyunda çalışıyor mu (OctoLogin.log)' 'Running in the game (OctoLogin.log)')
	$log = if ($ctx.Mods) { Ci $ctx.Mods 'OctoLogin.log' } else { $null }
	if (-not $log) {
		if ($Mode -eq 'check') {
			Warn (T 'OctoLogin hiç çalışmamış (log yok).' 'OctoLogin has never run (no log).')
			Info (T 'Oyunu VanillaFixes.exe (ya da OctoWoW launcher) ile başlattığından emin ol.' 'Make sure the game is started with VanillaFixes.exe (or the OctoWoW launcher).')
		} else {
			Info (T 'Henüz çalışmadı (normal). Oyunu açıp giriş yaptıktan sonra kontrol için: -Check' 'Not run yet (normal). To check after starting the game and logging in: -Check')
		}
		return
	}
	$logTime = (Get-Item -LiteralPath $log).LastWriteTime
	$when = $logTime.ToString('yyyy-MM-dd HH:mm')
	$lines = @(Get-Content -LiteralPath $log)
	$start = -1
	for ($i = $lines.Count - 1; $i -ge 0; $i--) { if ($lines[$i] -match '^[0-9:]+ OctoLogin [^ ]+: ') { $start = $i; break } }
	if ($start -lt 0) { Warn (T "Log'da başlangıç satırı yok." 'No start line in the log.'); return }
	$first = $lines[$start]
	$ver = if ($first -match '^[0-9:]+ OctoLogin ([^:]+): ') { $Matches[1] } else { '' }
	$ready = $first -match ': ready( |$)'
	if ($ready) {
		Ok (T "Oyunda yüklendi: OctoLogin $ver (son çalışma $when)" "Loaded in the game: OctoLogin $ver (last run $when)")
		if ($rel.Tag -and "v$ver" -ne $rel.Tag -and $ver -ne $rel.Tag) {
			Info (T "Son çalışan sürüm $ver; yeni sürüm ($($rel.Tag)) oyunu yeniden başlatınca yüklenir." "The last run used $ver; the new one ($($rel.Tag)) loads when the game starts again.")
		}
	} elseif ($first -match 'not WoW 1\.12\.1') {
		Bad (T 'Oyun istemcisi WoW 1.12.1 (5875) değil; OctoLogin çalışamaz.' 'The game client is not WoW 1.12.1 (5875); OctoLogin cannot work.')
	} elseif ($first -match 'already changed by another mod') {
		Bad (T "Başka bir mod oyunun connect'ini değiştiriyor (başka bir login/proxy modu?); OctoLogin devre dışı kaldı." "Another mod changes the game's connect (another login/proxy mod?); OctoLogin stayed off.")
		Info (T "dlls.txt'de OctoLogin'den önceki modlardan birini kaldırıp dene." 'Remove such a mod listed before OctoLogin in dlls.txt.')
	} else { Warn $first }
	if ($ctx.Dll -and (Test-Path -LiteralPath $ctx.Dll) -and (Get-Item -LiteralPath $ctx.Dll).LastWriteTime -gt $logTime) {
		Info (T "Bu bilgiler şimdi kurulan DLL'den önceki çalışmaya ait; oyunu başlatınca yenilenir." 'This is from a run before the DLL now installed; it renews when the game starts.')
	}
	if (-not $ready) { return }
	$rest = @($lines | Select-Object -Skip ($start + 1))
	if ($rest -match ': local proxy, left alone') {
		Warn (T "Son girişte realmlist yerel proxy'ydi (127.0.0.1); OctoLogin karışmadı." 'The last login used a local proxy (127.0.0.1); OctoLogin stayed out.')
	} elseif ($rest -match ': not an OctoWoW address, left alone') {
		Warn (T 'Son girişte realmlist OctoWoW adresi değildi; OctoLogin karışmadı.' 'The last login was not to an OctoWoW address; OctoLogin stayed out.')
	}
	$l = @($rest -match '^[0-9:]+ login: ') | Select-Object -Last 1
	if ($l) {
		$txt = $l -replace '^[0-9:]+ login: ', ''
		if ($l -match 'answered first') { Ok ((T 'Son giriş: ' 'Last login: ') + $txt) } else { Warn ((T 'Son giriş: ' 'Last login: ') + $txt) }
	} elseif ($rest.Count -eq 0) {
		Info (T 'O çalışmada giriş yapılmamış.' 'No login during that run.')
	}
	@($rest -match '^[0-9:]+ world [^ 0-9]' | Where-Object { $_ -notmatch ': testing ' }) | Select-Object -Last 6 |
		ForEach-Object { Info ($_ -replace '^[0-9:]+ ', '') }
}

function Remove-OctoLogin {
	Step (T 'Kaldırma' 'Uninstall')
	$f = Ci $ctx.GameDir 'dlls.txt'
	if ($f) {
		$d = Read-DllsTxt $f
		$keep = @($d.Lines | Where-Object { -not (Test-OctoLine $_) })
		if ($keep.Count -ne $d.Lines.Count) {
			Copy-Item -LiteralPath $f -Destination "$f.octologin-backup" -Force
			Write-DllsTxt $f $keep $d.Crlf
			Ok (T "dlls.txt'den çıkarıldı" 'Removed from dlls.txt')
		} else { Ok (T "dlls.txt'de OctoLogin yok" 'Not in dlls.txt') }
	} else { Ok (T "dlls.txt'de OctoLogin yok" 'Not in dlls.txt') }
	$mods = Ci $ctx.GameDir 'mods'
	$n = 0
	if ($mods) {
		foreach ($x in 'OctoLogin.dll', 'OctoLogin.ini', 'OctoLogin.log') {
			$p = Ci $mods $x
			if ($p) { Remove-Item -LiteralPath $p -Force; $n++ }
		}
	}
	Ok (T "mods klasöründen $n dosya silindi" "$n files deleted from mods")
}

# ------------------------------------------------------------------ main
try {
	$title = @{ install = (T 'kurulum' 'setup'); check = (T 'kontrol' 'check'); uninstall = (T 'kaldırma' 'uninstall') }[$Mode]
	Write-Host "OctoLogin $title" -ForegroundColor White

	Step (T 'Oyun klasörü' 'Game folder')
	$ctx.GameDir = Resolve-GameDir
	if (-not $ctx.GameDir) { return }
	Ok $ctx.GameDir

	if ($Mode -eq 'uninstall') {
		if (-not (Test-GameClosed)) { return }
		try { Remove-OctoLogin } catch { Bad $_.Exception.Message; if ($_.Exception -is [UnauthorizedAccessException]) { Write-AccessHint } }
		Write-Host ''
		return
	}

	Test-Loader
	if (-not (Test-GameClosed)) { return }
	Install-Dll
	Repair-DllsTxt
	Test-Settings
	Test-Launchers
	Test-Log

	Write-Host ''
	if ($st.Problems -gt 0) {
		Write-Host (T "$($st.Problems) sorun var; yukarıdaki [ XX ] satırlarına bak." "$($st.Problems) problem(s); see the [ XX ] lines above.") -ForegroundColor Red
	} elseif ($Mode -eq 'install') {
		if ($st.Warnings -gt 0) { Write-Host (T 'Kuruldu; [ !! ] satırlarına bir bak.' 'Installed; have a look at the [ !! ] lines.') -ForegroundColor Yellow }
		else { Write-Host (T 'Hazır.' 'Ready.') -ForegroundColor Green }
		Write-Host (T "Oyunu VanillaFixes.exe (ya da OctoWoW launcher) ile başlat. VanillaFixes `"will load additional DLLs`"`ndiye sorarsa OK'e bas. Girişten sonra kontrol için bu komutu -Check ile çalıştır." `
			"Start the game with VanillaFixes.exe (or the OctoWoW launcher). If VanillaFixes says it `"will load`nadditional DLLs`", press OK. To check after logging in, run this again with -Check.")
	} else {
		if ($st.Warnings -gt 0) { Write-Host (T 'Engel yok; [ !! ] satırlarına bir bak.' 'Nothing blocking; have a look at the [ !! ] lines.') -ForegroundColor Yellow }
		else { Write-Host (T 'Sorun yok.' 'No problems found.') -ForegroundColor Green }
	}
} catch {
	Write-Host ''
	Write-Host ((T 'Beklenmeyen hata: ' 'Unexpected error: ') + $_.Exception.Message) -ForegroundColor Red
	Write-Host $_.InvocationInfo.PositionMessage
}
} $Check.IsPresent $Uninstall.IsPresent $Game
