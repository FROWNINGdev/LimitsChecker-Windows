' Hidden launcher for LimitsChecker.ps1 - starts the tray app with no console
' window at all (powershell.exe -WindowStyle Hidden still flashes one).
Option Explicit
Dim fso, sh, dir, ps1, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = fso.BuildPath(dir, "LimitsChecker.ps1")
If Not fso.FileExists(ps1) Then
    MsgBox "LimitsChecker.ps1 not found next to this launcher:" & vbCrLf & ps1, 16, "LimitsChecker"
    WScript.Quit 1
End If
cmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """"
sh.CurrentDirectory = dir
sh.Run cmd, 0, False
