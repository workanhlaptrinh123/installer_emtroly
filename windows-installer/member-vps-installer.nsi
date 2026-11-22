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
!ifndef ICON_FILE
  !error "ICON_FILE must point to the brand icon (.ico)"
!endif

Name "installer_emtroly"
OutFile "${OUTFILE}"
Icon "${ICON_FILE}"
RequestExecutionLevel user
ManifestDPIAware true
SilentInstall silent
SetCompressor zlib

VIProductVersion "${FILE_VERSION}"
VIAddVersionKey "ProductName" "Anh Lap Trinh - Em Tro Ly"
VIAddVersionKey "ProductVersion" "${RELEASE_VERSION}"
VIAddVersionKey "FileVersion" "${FILE_VERSION}"
VIAddVersionKey "FileDescription" "Anh Lap Trinh - Em Tro Ly"
VIAddVersionKey "CompanyName" "Anh Lap Trinh"
VIAddVersionKey "LegalCopyright" "Copyright (c) Anh Lap Trinh"
VIAddVersionKey "OriginalFilename" "caidattroly.exe"

Section
  ${IfNot} ${RunningX64}
    MessageBox MB_ICONSTOP "This installer requires 64-bit Windows."
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
  ExecWait '"$WINDIR\Sysnative\WindowsPowerShell\v1.0\powershell.exe" -STA -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$PLUGINSDIR\windows-installer\wizard.ps1" -PayloadRoot "$PLUGINSDIR"' $0
  IfErrors launch_error
  SetErrorLevel $0
  Goto done
  launch_error:
    MessageBox MB_ICONSTOP "Cannot start Windows PowerShell installer."
    SetErrorLevel 1
  done:
SectionEnd
