Unicode true
!include "LogicLib.nsh"
!include "x64.nsh"

!ifndef PAYLOAD_DIR
  !error "PAYLOAD_DIR must point to the prepared installer payload"
!endif
!ifndef OUTFILE
  !error "OUTFILE must point to the executable to build"
!endif
!ifndef RELEASE_VERSION
  !error "RELEASE_VERSION must be set by the Windows build script"
!endif
!ifndef FILE_VERSION
  !error "FILE_VERSION must contain four numeric components"
!endif

Name "installer_emtroly"
OutFile "${OUTFILE}"
RequestExecutionLevel user
SilentInstall silent
SetCompressor /SOLID lzma

VIProductVersion "${FILE_VERSION}"
VIAddVersionKey "ProductName" "installer_emtroly"
VIAddVersionKey "ProductVersion" "${RELEASE_VERSION}"
VIAddVersionKey "FileVersion" "${FILE_VERSION}"
VIAddVersionKey "FileDescription" "installer_emtroly Windows installer"
VIAddVersionKey "CompanyName" "Anh Lap Trinh"

Section
  ${IfNot} ${RunningX64}
    MessageBox MB_ICONSTOP "Bộ cài yêu cầu Windows 64 bit."
    SetErrorLevel 1
    Quit
  ${EndIf}
  InitPluginsDir
  SetOutPath "$PLUGINSDIR"
  !ifdef WINDOWS_BUILD
  File /r "${PAYLOAD_DIR}\*"
  !else
  File /r "${PAYLOAD_DIR}/*"
  !endif
  ClearErrors
  ExecWait '"$WINDIR\Sysnative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$PLUGINSDIR\windows-installer\wizard.ps1" -PayloadRoot "$PLUGINSDIR"' $0
  IfErrors launch_error
  SetErrorLevel $0
  Goto done
  launch_error:
    MessageBox MB_ICONSTOP "Không thể mở Windows PowerShell để khởi động bộ cài."
    SetErrorLevel 1
  done:
SectionEnd
