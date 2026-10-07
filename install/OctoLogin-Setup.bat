@echo off
rem Installs OctoLogin, or checks it: double-click this file.
rem Put it in the game folder (next to WoW.exe) to skip the search.
rem   OctoLogin-Setup.bat -Check       only check, change nothing
rem   OctoLogin-Setup.bat -Uninstall   remove OctoLogin
set "OCTOLOGIN_DIR=%~dp0"
if not defined OCTOLOGIN_URL set "OCTOLOGIN_URL=https://raw.githubusercontent.com/fmustafayaman/OctoLogin/main/install/install.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072; $w = New-Object Net.WebClient; $w.Encoding = [Text.Encoding]::UTF8; & ([scriptblock]::Create($w.DownloadString($env:OCTOLOGIN_URL))) %*"
echo.
pause
