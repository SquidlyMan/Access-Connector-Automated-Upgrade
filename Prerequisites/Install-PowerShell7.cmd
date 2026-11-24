@echo off
REM ============================================================================
REM  Install-PowerShell7.cmd
REM  Starts Install-PowerShell7.ps1 (beside this file) in 64-bit Windows
REM  PowerShell 5.1, with the execution policy bypassed for that one process
REM  only. For a computer that has no PowerShell 7 yet.
REM
REM  Double-click it: it asks Windows for administrator rights when needed,
REM  installs or updates PowerShell 7, and waits for a key at the end so that
REM  the result can be read. (If Windows warns about a downloaded copy, open
REM  the file's Properties and tick Unblock first.)
REM
REM  Or run it from cmd.exe. Arguments go to the script unchanged, and then it
REM  neither asks for elevation nor waits for a key:
REM      Install-PowerShell7.cmd -CheckOnly
REM      Install-PowerShell7.cmd -MsiSource D:\Packages\PowerShell
REM      Install-PowerShell7.cmd -Help
REM  Do not end a quoted folder with a backslash ("D:\Packages\" -CheckOnly):
REM  Windows then reads \" as a quote that belongs to the folder name, the
REM  rest of the line joins it, and the script refuses the run. Write
REM  "D:\Packages", or "D:\IT Logs\\" for a log folder not yet created.
REM  The exit code is the script's (see -Help): 0, 3010 and 1641 mean success.
REM
REM  In a scheduled task, startup script or deployment tool, run the script
REM  itself, so that nothing can wait for a key (one line):
REM      powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass
REM          -File "C:\Tools\Install-PowerShell7.ps1"
REM  An execution policy set by Group Policy still applies: it wins over
REM  -ExecutionPolicy Bypass.
REM ============================================================================

setlocal EnableExtensions DisableDelayedExpansion

set "PS1=%~dp0Install-PowerShell7.ps1"

REM --- Optional pre-staged package, used only when this file is started
REM     without arguments (a double-click, or a startup script): an MSI file,
REM     or a folder holding PowerShell-<version>-win-<arch>.msi.
REM     Blank = download from GitHub.
set "MSISOURCE="
REM set "MSISOURCE=\\server.example.local\packages\PowerShell"

REM --- Who started it? INTERACTIVE = a person who should see the result.
set "INTERACTIVE="
set "ELEVATEDRUN="
set "RAN="
set "RC=1"
if /i "%~1"=="/elevated" (
    set "ELEVATEDRUN=1"
    set "INTERACTIVE=1"
    goto :checks
)
if not "%~1"=="" goto :checks
REM No arguments. A double-click shows this file's name in the cmd.exe command
REM line. SYSTEM (a startup script or a task) is never treated as a person.
if /i "%USERNAME%"=="%COMPUTERNAME%$" goto :checks
setlocal EnableDelayedExpansion
set "CL=!CMDCMDLINE!"
set "CLX=!CL:%~nx0=!"
if not "!CLX!"=="!CL!" (endlocal & set "INTERACTIVE=1") else endlocal

:checks
if exist "%PS1%" goto :ps1ok
echo [ERROR] Install-PowerShell7.ps1 was not found next to this launcher:
echo         "%PS1%"
goto :done
:ps1ok

REM --- 64-bit Windows PowerShell, also when this file runs in a 32-bit cmd.exe.
set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if defined PROCESSOR_ARCHITEW6432 set "PSEXE=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if exist "%PSEXE%" goto :psok
echo [ERROR] Windows PowerShell was not found: "%PSEXE%"
goto :done
:psok

REM --- A run without arguments installs, which needs administrator rights. If
REM     this window has none, ask Windows for them once: an elevated window then
REM     does the work and waits at the end, and this one closes. An elevated
REM     window does not see this user's mapped drives, so a path on one is
REM     handed over as its \\server\share path.
if defined ELEVATEDRUN goto :run
if not "%~1"=="" goto :run
fltmc >nul 2>&1
if not errorlevel 1 goto :run
echo Asking Windows for administrator rights ...
set "PS7_SELF=%~f0"
"%PSEXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "try { $p = $env:PS7_SELF; if ($p -match '^([A-Za-z]):\\') { $r = (Get-PSDrive -Name $Matches[1] -ErrorAction SilentlyContinue).DisplayRoot; if ($r -like '\\*') { $p = $r.TrimEnd('\') + $p.Substring(2) } }; Start-Process -FilePath $p -ArgumentList '/elevated' -Verb RunAs -ErrorAction Stop } catch { Write-Host ('[ERROR] ' + $_.Exception.Message); exit 1 }"
if errorlevel 1 goto :noelevation
exit /b 0
:noelevation
echo [ERROR] No administrator rights. Right-click Install-PowerShell7.cmd and
echo         choose Run as administrator, or run it from an elevated cmd.exe.
goto :done

:run
if not defined ELEVATEDRUN if not "%~1"=="" goto :withargs
if defined MSISOURCE goto :withsource
"%PSEXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%PS1%"
set "RC=%ERRORLEVEL%"
set "RAN=1"
goto :done

:withsource
REM A trailing backslash would escape the closing quote; "D:\Packages\." is the
REM same folder.
if "%MSISOURCE:~-1%"=="\" set "MSISOURCE=%MSISOURCE%."
"%PSEXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%PS1%" -MsiSource "%MSISOURCE%"
set "RC=%ERRORLEVEL%"
set "RAN=1"
goto :done

:withargs
"%PSEXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%PS1%" %*
set "RC=%ERRORLEVEL%"
set "RAN=1"
goto :done

:done
echo.
if defined RAN echo [INFO] Install-PowerShell7.ps1 returned %RC%
if defined INTERACTIVE pause
exit /b %RC%
