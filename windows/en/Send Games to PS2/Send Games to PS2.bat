@echo off
title PS2 - send games (udpfs)
rem Drag the ISOs (or their folder) onto this .bat. Needs the wLaunchELF FTP open on the PS2, on the main menu.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0send-games.ps1" %*
