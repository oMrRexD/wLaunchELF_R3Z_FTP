@echo off
title PS2 - mandar jogos (SIMULACAO)
rem Mesmo que o "Mandar jogos pro PS2.bat", mas sem tocar no PS2: mostra o que seria mandado e pra onde.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0mandar-jogos.ps1" -Simular %*
