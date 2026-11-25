@echo off
REM ============================================================================
REM  Install-PowerShell7.cmd - version 1.0.1, released with its .ps1
REM  Starts Install-PowerShell7.ps1 (beside this file) in 64-bit Windows
REM  PowerShell 5.1, with the execution policy bypassed for that one process
REM  only. For a computer that has no PowerShell 7 yet.
REM
REM  Double-click it: it asks Windows for administrator rights when needed and
REM  installs or updates PowerShell 7. (If Windows warns about a downloaded
REM  copy, open the file's Properties and tick Unblock first.)
REM
REM  Or run it from cmd.exe. Arguments go to the script unchanged, and then it
REM  does not ask for elevation:
REM      Install-PowerShell7.cmd -CheckOnly
REM      Install-PowerShell7.cmd -MsiSource D:\Packages\PowerShell
REM      Install-PowerShell7.cmd -Help
REM
REM  On failure it waits for a key, so that a double-clicked window stays open
REM  until the error is read: when the script's exit code is not 0, 3010 or
REM  1641, or the script could not be started. After a success (0) it ends at
REM  once (the run log holds the result). After 3010 or 1641 (installed, a
REM  restart is needed) it says to restart Windows, and waits for a key when
REM  it was started without arguments (double-clicked). It never waits when
REM  it runs as SYSTEM, or with -NoPause among the arguments (passed on to
REM  the script, which accepts it and does nothing with it; -NoPause:$true
REM  and -NoPa count too). The exit code is passed back either way.
REM
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
REM  (or give this launcher -NoPause).
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

REM --- NOPAUSE = never wait for a key: -NoPause among the arguments, or SYSTEM
REM     (a startup script or a task, where no person could press one).
set "NOPAUSE="
set "ELEVATEDRUN="
set "RAN="
set "RC=1"
REM An empty first argument ("") counts as an argument too: the script then
REM refuses it, instead of this file taking it for a double-click.
set "HASARGS="
if not [%1]==[] set "HASARGS=1"
if /i "%~1"=="/elevated" set "ELEVATEDRUN=1"
if /i "%USERNAME%"=="%COMPUTERNAME%$" set "NOPAUSE=1"
REM Look at every argument for -NoPause. SHIFT /1 moves only the numbered
REM arguments (this file's own name and path stay); the full argument list
REM handed to the script stays whole, and nothing below reads the first
REM argument again. (No CALL to a label: CALL shows its own help for /?.)
:scanargs
if [%1]==[] goto :checks
REM -NoPause as PowerShell binds it: also -NoPa, -NoPause:$true (the first
REM four characters; the script has no other parameter that starts -NoP).
set "ARG=%~1"
if /i "%ARG:~0,4%"=="-NoP" set "NOPAUSE=1"
shift /1
goto :scanargs

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
REM     does the work (and waits for a key only if it fails, or to say that a
REM     restart is needed), and this one closes. An elevated
REM     window does not see this user's mapped drives, so a path on one is
REM     handed over as its \\server\share path.
if defined ELEVATEDRUN goto :run
if defined HASARGS goto :run
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
if not defined ELEVATEDRUN if defined HASARGS goto :withargs
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
REM --- Success (0) ends at once. 3010 and 1641 (installed; a restart is
REM     needed) say so, and wait for a key in a window started without
REM     arguments (a double-click, or its elevated window), unless NOPAUSE.
REM     Anything else waits for a key, unless NOPAUSE. The exit code goes back
REM     as is.
if "%RC%"=="0" exit /b %RC%
if "%RC%"=="3010" goto :restart
if "%RC%"=="1641" goto :restart
if defined NOPAUSE exit /b %RC%
echo [ERROR] Install-PowerShell7 did not succeed (exit code %RC%). Read the
echo         messages above before this window closes.
goto :wait
:restart
echo [WARN] PowerShell 7 is installed. Restart Windows to finish the
echo        installation.
if defined NOPAUSE exit /b %RC%
if defined HASARGS if not defined ELEVATEDRUN exit /b %RC%
:wait
pause
exit /b %RC%
