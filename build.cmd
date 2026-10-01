@echo off
rem Builds AgentEmpire for this Windows PC. Double-click this file.
rem It downloads Godot (the game engine) the first time, then builds the game into the dist folder.
setlocal
cd /d "%~dp0"

where node >nul 2>nul
if errorlevel 1 (
  echo.
  echo AgentEmpire needs Node.js to build.
  echo Install the LTS version from https://nodejs.org and then double-click build.cmd again.
  echo.
  pause
  exit /b 1
)

node scripts\setup.mjs
if errorlevel 1 (
  echo.
  echo The setup stopped with an error; the lines above say why.
  echo.
  pause
  exit /b 1
)

node scripts\package-release.mjs --unpacked
if errorlevel 1 (
  echo.
  echo The build stopped with an error; the lines above say why.
  echo.
  pause
  exit /b 1
)

echo.
echo Done. Open the AgentEmpire folder inside "dist" and double-click AgentEmpire.exe.
start "" "%~dp0dist"
echo.
pause
