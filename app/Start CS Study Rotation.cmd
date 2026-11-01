@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0StudyRotation.ps1" -Action Start
endlocal
