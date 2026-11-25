@echo off
title Team Git Studio - installer_emtroly
cd /d "%~dp0"
echo Dang mo giao dien Team Git Studio (http://127.0.0.1:8765)...
python .agents\skills\git-team-flow\scripts\team_git.py ui --port 8765
if errorlevel 1 (
  echo.
  echo Khong tim thay lenh python. Thu chay bang py...
  py -3 .agents\skills\git-team-flow\scripts\team_git.py ui --port 8765
)
pause
