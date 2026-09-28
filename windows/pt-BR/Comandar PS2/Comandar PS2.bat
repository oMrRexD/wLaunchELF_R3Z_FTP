@echo off
title PS2 - comandar pela rede
rem Abre um app, volta pro OSDMenu ou desliga o PS2. Precisa do wLaunchELF FTP (R11+) no menu principal.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0comandar.ps1" %*
