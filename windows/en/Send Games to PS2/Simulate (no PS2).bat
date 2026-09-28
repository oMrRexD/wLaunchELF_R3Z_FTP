@echo off
title PS2 - send games (SIMULATION)
rem Same as "Send Games to PS2.bat", but without touching the PS2: shows what would be sent and where.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0send-games.ps1" -Simulate %*
