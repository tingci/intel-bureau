@echo off
rem ===========================================================================
rem  Intel Bureau - quick start
rem
rem  Thin wrapper: it does NOT reimplement anything. It only
rem    1. makes sure the venv exists (runs scripts\setup.ps1 if not), then
rem    2. hands over to the repo's own launcher (scripts\launch-hidden.vbs,
rem       which runs scripts\start.ps1 -Gui).
rem  So fixes made in the repo scripts are picked up automatically.
rem
rem  ASCII-only on purpose: .bat files are read under the console code page,
rem  so Chinese text here would turn into mojibake. The file NAME is Chinese,
rem  which is fine.
rem ===========================================================================
title Intel Bureau - quick start
cd /d "%~dp0"

if not exist "%~dp0scripts\start.ps1" goto nofiles

if exist "%~dp0.venv\Scripts\python.exe" goto launch

echo.
echo First run detected: no .venv found.
echo Creating the virtual environment and installing dependencies.
echo This takes a few minutes and needs internet. Do NOT close this window.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\setup.ps1"
if errorlevel 1 goto setupfailed

:launch
rem Some shells (notably AI agent sandboxes) export ELECTRON_RUN_AS_NODE=1.
rem WeChatDataAnalysis is an Electron app, and with that variable set it starts
rem as plain Node, prints nothing and exits 0 immediately -- so the 10392/10419
rem API never comes up. Clear it for the services this script starts.
set ELECTRON_RUN_AS_NODE=

rem Bring up WeChatDataAnalysis first when it is installed, so the WeChat
rem collector has something to talk to. Failure here is NOT fatal: the
rem workbench still starts, and the WeChat card will just show as disconnected.
rem (No parentheses blocks in this file on purpose -- see tests\test_launchers.py.)
if not exist "C:\Program Files\WeChatDataAnalysis\WeChatDataAnalysis.exe" goto nowda
if not exist "%~dp0scripts\start-wda.ps1" goto nowda
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-wda.ps1"
:nowda

if exist "%~dp0scripts\launch-hidden.vbs" if exist "%windir%\System32\wscript.exe" goto hidden

rem Fallback: no wscript, run the launcher directly (a console window stays open).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start.ps1" %*
set RC=%ERRORLEVEL%
goto done

:hidden
rem No console window: starts the service in the background and opens the
rem dashboard as an app-style window. Closing that window stops the service
rem after about 20 seconds.
start "" wscript.exe "%~dp0scripts\launch-hidden.vbs" %*
set RC=0
echo.
echo Starting the workbench in the background: http://127.0.0.1:8765
echo The dashboard window should open by itself in a moment.
echo   - To stop:        double-click "stop" bat in this folder
echo   - To see logs:    data\logs\launcher.log  and  data\logs\server-console.log
echo   - Health check:   .venv\Scripts\python.exe -X utf8 -m bureau doctor
echo.
goto done

:setupfailed
echo.
echo [SETUP FAILED] See the messages above.
echo Common causes: no internet, antivirus blocking, disk full.
echo.
pause
set RC=1
goto done

:nofiles
echo Cannot find scripts\start.ps1 next to this file.
echo Please unzip the whole package first, do not run it from inside the zip.
pause
set RC=1
goto done

:done
exit /b %RC%
