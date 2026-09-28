@echo off
title PS2 - commands over the network
rem Opens an app, goes back to OSDMenu or powers the PS2 off. Needs the wLaunchELF FTP on the main menu.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0command.ps1" %*
