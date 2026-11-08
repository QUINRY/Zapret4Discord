@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Invoke-Management.ps1" -Action Install
if errorlevel 1 pause
