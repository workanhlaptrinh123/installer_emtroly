Option Explicit
If WScript.Arguments.Count < 3 Then
  WScript.Quit 1
End If

Dim shell, psExe, wizardScript, payloadRoot, winStyle, command, exitCode
psExe = WScript.Arguments(0)
wizardScript = WScript.Arguments(1)
payloadRoot = WScript.Arguments(2)
If WScript.Arguments.Count >= 4 Then
  winStyle = WScript.Arguments(3)
Else
  winStyle = "-WindowStyle Hidden"
End If

Set shell = CreateObject("WScript.Shell")
shell.CurrentDirectory = payloadRoot
command = Chr(34) & psExe & Chr(34) & " -STA -NoLogo -NoProfile -ExecutionPolicy Bypass " & winStyle & " -File " & Chr(34) & wizardScript & Chr(34) & " -PayloadRoot " & Chr(34) & payloadRoot & Chr(34)
exitCode = shell.Run(command, 0, True)
Set shell = Nothing
WScript.Quit exitCode
