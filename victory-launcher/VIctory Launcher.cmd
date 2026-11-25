@echo off
rem Starts the VIctory Launcher (WPF, Windows PowerShell 5.1) without a console window.
start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0launcher\VIctory-Launcher.ps1"
