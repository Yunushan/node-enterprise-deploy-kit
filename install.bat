@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
pushd "%SCRIPT_DIR%" >nul

echo Starting Windows deployment wrapper...
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%install.ps1" %*
set "EXIT_CODE=%ERRORLEVEL%"

echo.
if not "%EXIT_CODE%"=="0" (
  echo Deployment failed with exit code %EXIT_CODE%.
) else (
  echo Deployment finished successfully.
)

pause
popd >nul
exit /b %EXIT_CODE%
