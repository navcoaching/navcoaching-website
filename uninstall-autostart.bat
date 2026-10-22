@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\windows\uninstall-autostart.ps1"
pause
