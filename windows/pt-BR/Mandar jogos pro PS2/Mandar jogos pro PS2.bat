@echo off
title PS2 - mandar jogos (udpfs)
rem Arraste as ISOs (ou a pasta delas) pra cima deste .bat. Precisa da R6 aberta no PS2, no menu principal.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0mandar-jogos.ps1" %*
