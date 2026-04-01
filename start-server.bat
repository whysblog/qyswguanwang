@echo off
cd /d %~dp0
powershell -ExecutionPolicy Bypass -File .\backend\server.ps1 -Port 8081
